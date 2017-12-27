require_relative 'rmk'
require_relative 'vdir'
require_relative 'vfile'
require 'open3'

class Rmk::Build
	attr_reader :dir
	attr_reader :infiles, :orderfiles, :outfiles

	# create Build
	# @param dir [Rmk::VDir] build's dir
	# @param rule [Rmk::Rule] build's rule
	# @param vars [Rmk::Vars] upstream vars
	# @param input [Array<Rmk::VFile>] input files
	# @param implicit_input [String, nil] implicit input raw string
	# @param order_only_input [String, nil] order-only input raw string
	# @param output [String, nil] output raw string
	# @param implicit_output [String, nil] implicit output raw string
	# @param collection [String, nil] collection name
	def initialize(dir, rule, vars, input, implicit_input, order_only_input, output, implicit_output, collection)
		@mutex = Thread::Mutex.new
		@updatedcnt = 0		# input file updated count
		@runed = false			# build has been runed
		@input_modified = false	# input file has modified

		@dir = dir
		@rule = rule
		@vars_we = Rmk::Vars.new vars		# outside writeable vars
		@vars = Rmk::Vars.new @vars_we	#
		@infiles = input

		if @infiles.size == 1
			if FFile === @infiles[0]
				vname = @infiles[0].vname
				if vname
					match = /^((?:[^\/]+\/)*)([^\/]*)$/.match vname
					@vars['in_dir'], @vars['in_nodir'] = match[1], match[2]
					match = /^(.*)\.(.*)$/.match match[2]
					@vars['in_base'], @vars['in_ext'] = match[1], match[2]
					@vars['in_noext'] = @vars['in_dir'] + @vars['in_base']
				end
				@vars['stem'] = @infiles[0].stem if @infiles[0].stem
				@infiles[0] = @infiles[0].vfile
			end
		end
		@vars['in'] = @infiles.map do |file|
			file.input_ref_builds << self
			next file.vpath unless file.src?
			file.vpath ? @dir.rmk.join_rto_src_path(file.vpath) : file.path
		end.join ' '

		@vars.split_str(implicit_input).each do |fn|
			files = @dir.find_inputfiles fn
			raise "pattern '#{fn}' not match any file" if files.empty?
			files.each{|f| f.input_ref_builds << self}
		end if implicit_input

		@orderfiles = []
		@vars.split_str(order_only_input).each do |fn|
			files = @dir.find_inputfiles fn
			raise "pattern '#{fn}' not match any file" if files.empty?
			files.each{|f| f.order_ref_builds << self}
		end if order_only_input

		@outfiles = []
		regout = proc do |fn|
			file = @dir.add_out_file fn
			file.output_ref_build = self
			@outfiles << file
		end
		output = @rule['out'] || raise('must have output') unless output
		@vars.split_str(output).each &regout
		collection.each{|col| col.concat @outfiles} if collection
		@vars['out'] = @outfiles.map {|file| file.vpath || file.path}.join ' '
		@vars['out_noext'] = @vars['out'][/^(.*)\..*$/, 1] if @outfiles.size == 1
		@rule.vars.each {|name, str| @vars_we[name] = @vars.interpolate_str str}	# interpolate rule's vars to self
		@vars.split_str(implicit_output).each &regout if implicit_output
		@vars.freeze
	end

	def vars; @vars.upstream_writer end

	def input_updated!(modified, order:false)
		Rmk::Schedule.new_thread! &method(:run) if @mutex.synchronize do
			next if @runed
			@updatedcnt += 1
			@input_modified ||= order ? modified == :create : modified
			needrun = @updatedcnt >= @infiles.size + @orderfiles.size
			@runed = true if needrun
			needrun
		end
	end

	def order_updated!(modified) input_updated! modified, order:true end

	@output_mutex = Thread::Mutex.new
	def self.puts(*parms) @output_mutex.synchronize{$stdout.puts *parms} end
	def self.err_puts(*parms) @output_mutex.synchronize{$stderr.puts *parms} end
	def self.log_cmd_out(out, err)
		@output_mutex.synchronize do
			$stdout.puts out unless out.empty?
			$stderr.puts err unless err.empty?
		end
	end

	private def run
		exec = nil
		modifieds = @outfiles.map{|file| File.exist?(file.path) ? true : (exec = :create)}
		return @outfiles.each{|file| file.updated! false} unless @input_modified ||  exec
		@vars['depfile'] ||= (@outfiles[0].vpath || @outfiles[0].path) + '.dep' if @vars['deptype']
		cmd = @vars.interpolate_str @vars['command'] || @rule.command
		unless /^\s*$/.match? cmd
			env = {}
			env['PATH'] = @vars['PATH_prepend'] + ENV['PATH'] if @vars['PATH_prepend']
			@vars['ENV_export'].split(/\s+/).each{|name| env[name] = @vars[name] if @vars.include? name} if @vars['ENV_export']
			std, err, result = env.empty? ? Open3.capture3(cmd) : Open3.capture3(env, cmd)
			std = std.empty? ? @vars['echo'] || "Rmk: run: #{cmd}" : (@vars['echo'] || "Rmk: run: #{cmd}") + ?\n + std
			if result.exitstatus != 0
				err = "execute faild: '#{cmd}'" if err.empty?
				Rmk::Build.log_cmd_out std, err
				return @outfiles.each{|file| File.delete file.path if File.exist? file.path}
			end
			Rmk::Build.log_cmd_out std, err
		end
		@outfiles.size.times {|i| @outfiles[i].updated! modifieds[i]}
		return unless @vars['deptype']
		unless File.exist? @vars['depfile']
			Rmk::Build.err_puts "Rmk: depend file '#{@vars['depfile']}' which must be created by build '#{@vars['out']}' not found"
		end
		if @vars['deptype'] == 'make'
			files = parse_make_depfile @vars['depfile']
			File.delete @vars['depfile']
			return Rmk::Build.err_puts "Rmk: syntax of depend file '#{@vars['depfile']}' not support yet" unless files
			@dir.rmk.dep_storage[@outfiles[0].path] = files
			files.each do |file|
				file = File.absolute_path Rmk.normalize_path(file), @dir.rmk.outroot
				next if @dir.rmk.srcfiles.include?(file) || @dir.rmk.outfiles.include?(file)
				outs = @outfiles.map{|out| out.vpath || out.path}
				@dir.rmk.src_list_storage.sync{|data| data[file] ? data[file].concat(outs) : data[file] = outs}
				@dir.rmk.mid_storage.sync{|data| data[file] ||= Rmk::VFile.generate_modified_id(file)}
			end
		else
			Rmk::Build.err_puts "Rmk: depend type '#{@vars['deptype']}' not support"
		end
	end

	def parse_make_depfile(path)
		lines = IO.readlines path
		line, lid = lines[0], 0
		_, _, line = line.partition /(?<!\\)(?:\\\\)*\K:\s+/
		return unless line
		files = []
		while lid < lines.size
			joinline = line.sub! /(?<!\\)(?:\\\\)*\K\\\n\z/,''
			parms = line.split /(?<!\\)(?:\\\\)*\K\s+/
			unless parms.empty?
				parms.delete_at 0 if parms[0].empty?
				parms.map!{|parm| File.absolute_path parm.gsub(/\\(.)/, '\1')}
				files.concat parms
			end
			break unless joinline
			lid += 1
			line = lines[lid]
		end
		files
	end
end
