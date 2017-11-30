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
		@virtual_root.parse
	end
	attr_reader :srcroot, :outroot, :src_relative, :virtual_root, :srcfiles

	# join src file path relative to out root, or absolute src path when not relative src
	def join_rto_src_path(path) ::File.join @src_relative ? @src_relative : @srcroot, path end

	def build(*tgts)
	end

	class Vars; end
	class Rule < Vars
		def vars; self end
	end
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

class Rmk::Build
	attr_reader :dir
	attr_reader :infiles, :orderfiles, :outfiles
	attr_reader :vars

	# create Build
	# @param dir [Rmk::Dir] build's dir
	# @param vars [Rmk::Vars] build's vars, setup outside becouse need preset some vars
	def initialize(dir, vars, input, implicit_input, order_only_input, output, implicit_output)
		@dir = dir
		@vars = vars
		@infiles = []
		regin = proc{|fn| @infiles << dir.reg_in_file(self, fn)}
		input.each &regin
		@vars['in'] = @infiles.map{|f| %|"#{f['path']}"|}.join ' '
		implicit_input.each &regin if implicit_input
		@orderfiles = []
		order_only_input.each{|fn| @orderfiles << dir.reg_order_file(self, fn)} if order_only_input
		@outfiles = []
		regout = proc {|fn| @outfiles << dir.add_out_file(self, fn)}
		output.each &regout
		@vars['out'] = @outfiles.map{|f| %|"#{f['path']}"|}.join ' '
		implicit_output.each &regout if implicit_output
	end

	def run
		cmd = @vars['command']
		unless cmd.empty?
			cmd = cmd.gsub(/\$(?:(\$)|(\w+)|{(\w+)})/){case when $1 then $1 when $2 then @vars[$2] else @vars[$3] end}
			result = system cmd
		end
		@outfiles.each do |f|
			f[:state] = :updated
			f[:obuild].need_run! if f.include? :obuild
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

	def find_inputfiles(pattern)
		pattern = Rmk.normalize_path pattern
		files = find_srcfiles pattern
		return files if pattern.match? /^[a-z]:/i
		files.concat find_outfiles(pattern)
	end

	def find_srcfiles(pattern)
		raise "file pattern can't be absolute path" if pattern.match? /^[a-z]:/i
		match = /^((?:[^\/\*]+\/)*)([^\/\*]*)(?:\*([^\/\*]*))?$/
		raise "file syntax '#{pattern}' error" unless match
		Dir[pattern].map! {|fn| @rmk.srcfiles[fn] || (@rmk.srcfiles[fn] = {path: fn, src?: true})}
	end

	# add a output file
	# @param name file name, must relative to this dir
	def add_out_file(build, name)
		name = @vars.unescape_str name
		rpath = @path.empty? ? name : ::File.join(@path, name)
		@outfiles[name] = {ibuild:build, path:rpath, state: :parsed}
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
			vars = Rmk::Vars.new @rules[match[:rule]].vars
			if eachmode
				iparms[0].each do |fn|
					files = find_inputfiles fn
					nvars = Rmk::Vars.new vars
					@builds << Rmk::Build.new(self, nvars, iparms[0], iparms[1], iparms[2], oparms[0], oparms[1])
				end
			else
				@builds << Rmk::Build.new(self, Rmk::Vars.new(vars), iparms[0], iparms[1], iparms[2], oparms[0], oparms[1])
			end
			@state << {indent:indent, type: :AcceptVar, condition:state[:condition], vars:vars}
		when 'default'
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
