require_relative 'rmk'
require_relative 'vdir'
require_relative 'vfile'

class Rmk::Build
	attr_reader :dir
	attr_reader :infiles, :orderfiles, :outfiles
	attr_reader :vars

	# create Build
	# @param dir [Rmk::VDir] build's dir
	# @param vars [Rmk::Vars] build's vars, setup outside becouse need preset some vars
	# @param input [Array<Rmk::VFile>] input files
	# @param implicit_input [String, nil] implicit input raw string
	# @param order_only_input [String, nil] order-only input raw string
	# @param output [String, nil] output raw string
	# @param implicit_output [String, nil] implicit output raw string
	def initialize(dir, vars, input, implicit_input, order_only_input, output, implicit_output)
		@dir = dir
		@vars = vars
		@infiles = input
		@vars['in'] = @infiles.map do |file|
			file.input_ref_builds << self
			next file.vpath unless file.src?
			file.vpath ? @dir.rmk.join_rto_src_path(file.vpath) : file.path
		end.join ' '
		if @infiles.size == 1 && @infiles[0].vpath
			vpath = @infiles[0].vpath
			@vars['vin'] = vpath
			match = /^((?:[^\/]+\/)*)([^\/]*)$/.match vpath
			@vars['vin_dir'], @vars['vin_nodir'] = match[1], match[2]
			match = /^(.*)\.(.*)$/.match match[2]
			@vars['vin_base'], @vars['vin_ext'] = match[1], match[2]
			@vars['vin_noext'] = @vars['vin_dir'] + @vars['vin_base']
		end

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
			file.output_ref_builds << self
			@outfiles << file
		end
		Rmk.split_parms(@vars.preprocess_str output).each &regout
		@vars['out'] = @outfiles.map {|file| file.vpath || file.path}.join ' '
		@vars['out_noext'] = @vars['out'][/^(.*)\..*$/, 1] if @outfiles.size == 1
		Rmk.split_parms(@vars.preprocess_str implicit_output).each &regout if implicit_output
	end

	def run
		cmd = @vars['command']
		unless cmd.empty?
			cmd = cmd.gsub(/\$(?:(\$)|(\w+)|{(\w+)})/){case when $1 then $1 when $2 then @vars[$2] else @vars[$3] end}
			result = system cmd
		end
		@outfiles.each do |f|
			f.state = :updated
			f.input_ref_builds&.each{|build| build.need_run!}
		end if result
	end
end
