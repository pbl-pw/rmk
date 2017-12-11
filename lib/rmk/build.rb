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
	def initialize(dir, rule, vars, input, implicit_input, order_only_input, output, implicit_output, stem:nil)
		@mutex = Thread::Mutex.new
		@updatedcnt = 0		# input file updated count
		@runed = false			# build has been runed
		@input_modified = false	# input file has modified

		@dir = dir
		@rule = rule
		@vars_we = Rmk::Vars.new vars		# outside writeable vars
		@vars = Rmk::Vars.new @vars_we	#
		@infiles = input

		@vars['in'] = @infiles.map do |file|
			file.input_ref_builds << self
			next file.vpath unless file.src?
			file.vpath ? @dir.rmk.join_rto_src_path(file.vpath) : file.path
		end.join ' '
		if @infiles.size == 1 && @infiles[0].vname
			vname = @infiles[0].vname
			match = /^((?:[^\/]+\/)*)([^\/]*)$/.match vname
			@vars['in_dir'], @vars['in_nodir'] = match[1], match[2]
			match = /^(.*)\.(.*)$/.match match[2]
			@vars['in_base'], @vars['in_ext'] = match[1], match[2]
			@vars['in_noext'] = @vars['in_dir'] + @vars['in_base']
		end
		@vars['stem'] = stem if stem

		Rmk.split_parms(@vars.preprocess_str implicit_input).each do |fn|
			fn = @vars.unescape_str fn
			files, _ = @dir.find_inputfiles fn
			raise "pattern '#{fn}' not match any file" if files.empty?
			files.each{|f| f.input_ref_builds << self}
		end if implicit_input

		@orderfiles = []
		Rmk.split_parms(@vars.preprocess_str order_only_input).each do |fn|
			fn = @vars.unescape_str fn
			files, _ = @dir.find_inputfiles fn
			raise "pattern '#{fn}' not match any file" if files.empty?
			files.each{|f| f.order_ref_builds << self}
		end if order_only_input

		@outfiles = []
		regout = proc do |fn|
			file = dir.add_out_file @vars.unescape_str fn
			file.output_ref_build = self
			@outfiles << file
		end
		output = @rule['out'] || raise('must have output') unless output
		Rmk.split_parms(@vars.preprocess_str output).each &regout
		@vars['out'] = @outfiles.map {|file| file.vpath || file.path}.join ' '
		@vars['out_noext'] = @vars['out'][/^(.*)\..*$/, 1] if @outfiles.size == 1
		@rule.vars.each {|name, str| @vars_we[name] = @vars.interpolate_str str}	# interpolate rule's vars to self
		Rmk.split_parms(@vars.preprocess_str implicit_output).each &regout if implicit_output
		@vars.freeze
	end

	def vars; @vars.upstream_writer end

	def input_updated!(modified, order:false)
		@dir.rmk.new_thread! &method(:run) if @mutex.synchronize do
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
		if @input_modified || @outfiles.any?{|file| !File.exist? file.path}
			cmd = @vars.interpolate_str @vars['command'] || @rule.command
			unless /^\s*$/.match? cmd
				Rmk::Build.puts @vars['echo'] || cmd
				result = system cmd
				return Rmk::Build.err_puts "can't excute command\n" if result.nil?
				return unless result
			end
			@outfiles.each do |file|
				file.updated! true
				@dir.rmk.file_store_modified_id file
			end
		else
			@outfiles.each{|file| file.check_for_build}
		end
	end
end
