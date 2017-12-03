require 'rmk/version'

class Rmk
	# normalize path, drive letter upcase and path seperator set to '/'
	# @param path [String]
	# @return [String]
	def self.normalize_path(path) path.gsub(?\\, ?/).sub(/^[a-z](?=:)/){|ch|ch.upcase} end

	# split parms using un-escape space as separator
	# @param line [String] str to split
	# @param sep [String] regex for separator
	# @return [Array<String>]
	def self.split_parms(line, sep = '\s+')
		result = []
		until line.empty?
			head, match, line = line.partition /(?<!\$)((?:\$\$)*)#{sep}/
			break result << head if match.empty?
			result << head + $1 unless head.empty? && $1.empty?
		end
		result
	end

	# create Rmk object
	# @param srcroot [String] source file root dir, can be absolute path or relative to outroot path(start with '../')
	def initialize(srcroot, outroot = '')
		@srcroot = Rmk.normalize_path(::File.absolute_path srcroot, outroot)
		@outroot = Rmk.normalize_path(::File.absolute_path outroot)
		@src_relative = srcroot.match?(/^\.\.[\\\/]/) && Rmk.normalize_path(srcroot)
		@virtual_root = Rmk::Dir.new self, nil
		::Dir.mkdir @outroot unless Dir.exist? @outroot
		@srcfiles = {}
		@outfiles = {}
		@virtual_root.parse
	end
	attr_reader :srcroot, :outroot, :src_relative, :virtual_root, :srcfiles, :outfiles

	# join src file path relative to out root, or absolute src path when not relative src
	def join_rto_src_path(path) ::File.join @src_relative ? @src_relative : @srcroot, path end

	def find_inputfile(path)
		# mutex lock if multithread
		return @outfiles[path] if @outfiles.include? path
		return @srcfiles[path] if @srcfiles.include? path
		raise "file '#{path}' not exist" unless ::File.exist? path
		@srcfiles[path] = VFile.new path:path, is_src:true
		# mutex unlock if multithread
	end

	# register a out file
	# @param file [Rmk::VFile] virtual file object
	# @return [Rmk::VFile] return file obj back
	def add_out_file(file)
		raise "file '#{file.path}' has been defined" if @outfiles.include? file.path
		@srcfiles.delete file.path if @srcfiles.include? file.path
		@outfiles[file.path] = file
	end

	# add default target
	def add_default(*files)
		# need implement
	end

	def build(*tgts)
	end

	class Vars; end
	class Rule < Vars
		def vars; self end
	end
	class VFile; end
end

class Rmk::Vars
	# create vars
	# @param upstream [Rmk::Vars, nil] upstream vars for lookup var which current obj not include
	def initialize(upstream, **presets) @upstream, @vars = upstream, presets end

	def [](name) (@vars.include?(name) ? @vars[name] : @upstream&.[](name)).to_s end

	def []=(name, value) @vars[name] = value end

	def include?(name) @vars.include?(name) || @upstream&.include?(name) end

	# only do #{\w+} interpolate
	def preprocess_str(str) str.gsub(/\$((?:\$\$)*){(\w+)}/){"#{$1}#{self[$2]}"} end

	# do all '$' prefix escape str interpolate
	def unescape_str(str) str.gsub(/\$(?:([\$\s>&])|(\w+))/){$1 || self[$2]} end

	# preprocess str, and then unescape the result
	def interpolate_str(str) unescape_str preprocess_str str end
end

# virtual file which represent a real OS file
class Rmk::VFile
	attr_reader :path, :vpath
	attr_accessor :is_src

	def src?; @is_src end

	# builds which include this file as input file
	def input_ref_builds; @ibuilds end

	# builds which include this file as order-only file
	def order_ref_builds; @odbuilds end

	# builds which include this file as output file
	def output_ref_builds; @obuilds end

	def initialize(path:, vpath:nil, is_src:false)
		@path, @vpath, @is_src = path, vpath, is_src
		@ibuilds = []
		@obuilds, @odbuilds = [], [] unless is_src
	end
end

class Rmk::Build
	attr_reader :dir
	attr_reader :infiles, :orderfiles, :outfiles
	attr_reader :vars

	# create Build
	# @param dir [Rmk::Dir] build's dir
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
			file.vpath ? @dir.rmk.join_rto_src_path file.vpath : file.path
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

class Rmk::Dir
	attr_reader :rmk, :abs_src_path, :abs_out_path
	attr_reader :srcfiles, :outfiles, :builds
	attr_reader :vars, :rules, :subdirs
	attr_writer :defaultfile
	protected :defaultfile=

	# create virtual dir
	# @param rmk [Rmk] Rmk obj
	# @param parent [Rmk::Dir, nil] parent virtual dir, or nil for root
	# @param path [String] path relative to parent, or empty for root
	def initialize(rmk, parent, path = '')
		@rmk = rmk
		@defaultfile = nil
		@vars = Rmk::Vars.new(nil)
		@rules = {}
		@subdirs = {}
		@srcfiles = {}
		@outfiles = {}
		@builds = []
		@virtual_path = parent&.join_virtual_path path
		@abs_src_path = ::File.join @rmk.srcroot, @virtual_path, ''
		@abs_out_path = ::File.join @rmk.outroot, @virtual_path, ''
	end

	def include_subdir(path)
		return @subdirs[path] if @subdirs.include? path
		dir = @subdirs[path] = Rmk::Dir.new @rmk, self, path
		dir.defaultfile = @defaultfile
		dir
	end

	def join_abs_src_path(file) ::File.join @abs_src_path, file end

	def join_abs_out_path(file) ::File.join @abs_out_path, file end

	def join_virtual_path(file) @virtual_path ? ::File.join(@virtual_path, file) : file end

	# join src file path relative to out root, or absolute src path when not relative src
	def join_rto_src_path(file) @rmk.join_rto_src_path join_virtual_path(file) end

	# split virtual path pattern to dir part and file match regex part
	# @param pattern [String] virtual path, can include '*' to match any char at last no dir part
	# @return [Array(String, <Regex, nil>)] when pattern include '*', return [dir part, file match regex]
	# ;otherwise return [origin pattern, nil]
	def split_vpath_pattern(pattern)
		match = /^((?:[^\/\*]+\/)*)([^\/\*]*)(?:\*([^\/\*]*))?$/.match pattern
		raise "file syntax '#{pattern}' error" unless match
		dir, prefix, postfix = *match[1..3]
		regex = postfix && /#{Regexp.escape prefix}(.*)#{Regexp.escape postfix}$/
		[regex ? dir : pattern, regex]
	end

	# find files which can be build's imput file
	# @param pattern [String] virtual path to find src and out files which can include '*' to match any char at last no dir part
	# ;or absolute path to find a src file which not in src tree
	# @return [Array(Array<Hash>, <Regex,nil>)] return [files, regex], or [files, nil] when not include '*' pattern
	def find_inputfiles(pattern)
		pattern = Rmk.normalize_path pattern
		if pattern.match? /^[A-Z]:/
			file = @rmk.find_inputfile pattern
			return [file && [file] || [], nil]
		end
		dir, regex = split_vpath_pattern pattern
		files = find_srcfiles_imp pattern
		files.concat find_outfiles_imp  dir, regex
		[files, regex]
	end

	# find srcfiles raw implement(assume all parms valid)
	# @param pattern [String] virtual path, can include '*' to match any char at last no dir part
	# @return [Array<Hash>]
	protected def find_srcfiles_imp(pattern)
		Dir[join_abs_src_path pattern].map! do |fn|
			next @srcfiles[fn] if @srcfiles.include? fn
			@srcfiles[fn] = VFile.new path: fn, vpath:fn[@rmk.srcroot.size + 1 .. -1], is_src: true
		end
	end

	# find outfiles raw implement(assume all parms valid)
	# @param path [String] virtual path, if regex, path must be dir(end with '/') or empty, otherwise contrary
	# @param regex [Regexp, nil] if not nil, file match regexp
	# @return [Array<Hash>]
	protected def find_outfiles_imp(path, regex)
		files = []
		if regex
			@outfiles.each{|k,v| files << v if k.start_with?(path) && k[path.size .. -1].match?(regex)}
		else
			files << @outfiles[path] if @outfiles.include? path
		end
		return files unless path.sub! /^([^\/]+)\//, ''
		subdir = $1
		return files unless @subdirs.include? subdir
		files + @subdirs[subdir].find_outfiles_imp(path, regex)
	end

	# find files which must be build's output
	# @param pattern [String] virtual path to find out files which can include '*' to match any char at last no dir part
	# @return [Array<Hash>] return Array of file, and Regex when has '*' pattern
	def find_outfiles(pattern) find_outfiles_imp *split_vpath_pattern(pattern) end

	# add a output file
	# @param name file name, must relative to this dir
	# @return [VFile] virtual file object
	def add_out_file(name)
		name = @vars.unescape_str name
		@outfiles[name] = @rmk.add_out_file VFile.new(path:join_abs_out_path(name), vpath:join_virtual_path(name))
	end

	private def begin_define_nonvar(indent)
		last = @state[-1]
		case last[:type]
		when :AcceptVar		# rule or build context which can add var
			@state.pop
			last = @state[-1]
			raise 'invalid indent' unless indent == last[:indent]
		when :SubVar
			@state.pop 2
			last = @state[-1]
			raise 'invalid indent' unless indent == last[:indent]
		when :Condition	# just after condition context
			raise 'invalid indent' unless indent > last[:indent]
			@state << {indent:indent, type:nil, condition:last[:condition], vars:last[:vars]}
			last = @state[-1]
		else			# general context
			raise 'invalid indent' unless indent == last[:indent]
		end
		last
	end

	private def end_last_define
		last = @state[-1]
		if last[:type] == :SubVar
			@state.pop 2
		elsif last[:type] == :AcceptVar
			@state.pop
		end
	end

	def define_var(indent, name, value)
		last = @state[-1]
		case last[:type]
		when :AcceptVar		# rule or build context which can add var
			raise 'invalid indent' if indent < last[:indent]
			if indent > last[:indent]
				@state << {indent:indent, type: :SubVar, condition:last[:condition], vars:last[:vars]}
				last = @state[-1]
			else
				@state.pop
				last = @state[-1]
				raise 'invalid indent' unless indent == last[:indent]
			end
		when :Condition	# just after condition context
			raise 'invalid indent' unless indent > last[:indent]
			@state << {indent:indent, type:nil, condition:last[:condition], vars:last[:vars]}
			last = @state[-1]
		else			# general context
			raise 'invalid indent' unless indent == last[:indent]
		end
		last[:vars][name] = last[:vars].interpolate_str value
	end

	def parse
		raise "dir '#{@abs_src_path}' has been parsed" if @state
		@state = []
		file = join_abs_src_path 'default.rmk'
		@defaultfile = file if ::File.exist? file
		file = join_abs_out_path 'config.rmk'
		parse_file file if ::File.exist? file
		file = join_abs_src_path 'dir.rmk'
		if ::File.exist? file
			parse_file file
		elsif @defaultfile
			parse_file @defaultfile
		else
			raise "dir parse error: '#{file}' doesn't exist and can't finded any 'default.mk'"
		end
	end

	def parse_file(file)
		last_state, @state = @state, [{indent:0, type:nil, condition:nil, vars:@vars}]
		lines = IO.readlines file
		lid = 0
		while lid < lines.size
			line, markid = '', lid
			while lid < lines.size
				break if lines[lid].sub!(/(?<!\$)((?:\$\$)*)#.*$/){$1}
				break unless lines[lid].sub!(/(?<!\$)((?:\$\$)*)\$\n/m){$1}
				line += lines[lid]
				lid += 1
			end
			parse_line lid < lines.size ? line + lines[lid] : line, markid
		end
		@state = last_state
	end

	def parse_line(line, lid)
		match = /^(?<indent> *|\t*)(?:(?<firstword>\w+)(?:\s*|\s+(?<content>.*)))?$/.match line
		raise 'syntax error' unless match
		indent, firstword, line = match[:indent].size, match[:firstword], match[:content]
		return end_last_define unless firstword
		state = @state[-1]
		if !state[:condition].nil? && !state[:condition]		# false state fast process
			@state.pop if indent == state[:indent] && firstword == 'endif'
			return
		end
		case firstword
		when /^if(n)?(?:(eq)|def)$/
			logicnot, logicmod = Regexp.last_match(1), Regexp.last_match(2)
			state = begin_define_nonvar indent
			parms = Rmk.split_parms state[:vars].preprocess_str line
			if logicmod
				raise 'must have two str' unless parms.size == 2
				parms[0] = state[:vars].unescape_str parms[0]
				parms[1] = state[:vars].unescape_str parms[1]
				value = logicnot ? parms[0] != parms[1] : parms[0] == parms[1]
			else
				raise 'must have var name' if parms.empty?
				value = logicnot ? parms.all?{|parm| !@vars.include? state[:vars].unescape_str parm} :
					parms.all?{|parm| @vars.include? state[:vars].unescape_str parm}
			end
			@state << {indent:indent, type: :Condition, condition:value, vars:state[:vars]}
		when 'else', 'endif'
			raise 'syntax error' if line
			endmod = firstword != 'else'
			while state
				raise 'not if condition' if state[:condition].nil?
				if state[:type]&.== :Condition
					raise 'invalid indent' unless indent == state[:indent]
					return endmod ? @state.pop : state[:condition] = false
				end
				@state.pop
				state = @state[-1]
			end
			raise 'not found match if'
		when 'rule'
			match = /^(?<name>\w+)\s*(?:=\s*(?<command>.*))?$/.match line
			raise 'rule name or command invalid' unless match
			state = begin_define_nonvar indent
			raise "rule '#{match[:name]}' has been defined" if @rules.include? match[:name]
			rule = @rules[match[:name]] = Rmk::Rule.new state[:vars], 'command'=>command
			@state << {indent:indent, type: :AcceptVar, condition:state[:condition], vars:rule.vars}
		when /^build(each)?$/
			eachmode = Regexp.last_match 1
			state = begin_define_nonvar indent
			match = /^(?<rule>\w+)\s+(?<parms>.*)$/.match line
			raise 'syntax error' unless match
			raise "rule '#{match[:rule]}' undefined" unless @rules.include? match[:rule]
			parms = Rmk.split_parms match[:parms], '>>'
			raise "must have '>>' separator for separat input and output" unless parms.size == 2
			iparms = Rmk.split_parms parms[0], '&'
			raise 'input syntax error' unless (1..3) === iparms.size
			oparms = Rmk.split_parms parms[1], '&'
			raise 'output syntax error' unless (1..2) === oparms.size
			iparms[0] = Rmk.split_parms(state[:vars].preprocess_str iparms[0]).map!{|fn| state[:vars].unescape_str fn}
			raise 'must have input file' if iparms[0].size == 0
			vars = Rmk::Vars.new @rules[match[:rule]].vars
			if eachmode
				iparms[0].each do |fn|
					files, regex = find_inputfiles fn
					files.each do |file|
						nvars = Rmk::Vars.new vars
						nvars[:in_stem] = file[:vpath][regex, 1] if regex
						@builds << Rmk::Build.new(self, nvars, [file], iparms[1], iparms[2], oparms[0], oparms[1])
					end
				end
			else
				files = []
				iparms[0].each {|fn| files.concat find_inputfiles(fn)[0]}
				@builds << Rmk::Build.new(self, Rmk::Vars.new(vars), files, iparms[1], iparms[2], oparms[0], oparms[1])
			end
			@state << {indent:indent, type: :AcceptVar, condition:state[:condition], vars:vars}
		when 'default'
			state = begin_define_nonvar indent
			parms = Rmk.split_parms state[:vars].preprocess_str line
			raise "must have file name" if parms.empty?
			parms.each do |parm|
				files = find_outfiles parm
				raise "pattern '#{parm}' not match any out file" if files.empty?
				@rmk.add_default *files
			end
		when 'include'
			state = begin_define_nonvar indent
			parms = Rmk.split_parms state[:vars].preprocess_str line
			raise "#{lid}: must have file name" if parms.empty?
			parms.each do |parm|
				parm = state[:vars].unescape_str parm
				if parm.match? /^[a-zA-Z]:/
					raise "file '#{parm}' not exist" unless ::File.exist? parm
					parse_file parm
				else
					file = join_abs_out_path parm
					next parse_file file if ::File.exist? file
					file = join_abs_src_path parm
					next parse_file file if ::File.exist? file
					raise "file '#{parm}' not exist"
				end
			end
		when 'incdir'
			state = begin_define_nonvar indent
			parms = Rmk.split_parms state[:vars].preprocess_str line
			raise "#{lid}; must have dir name or matcher" if parms.empty?
			parms.each do |parm|
				parm = state[:vars].unescape_str parm
				dirs = ::Dir[::File.join @abs_src_path, parm, '']
				raise "#{lid}: subdir '#{parm}' doesn't exist" if dirs.empty?
				dirs.each do |dir|
					dir = include_subdir dir.sub @abs_src_path, ''
					new_thread {dir.parse}
				end
			end
			join_threads
		else
			match = /^=\s*(?<value>.*)$/.match line
			raise 'syntax error' unless match
			define_var indent, firstword, match[:value]
		end
	end

	# run in new thread
	# @note not ready
	def new_thread(&cmd) cmd.call end

	# wait all threads
	# @note not ready
	def join_threads; end
end
