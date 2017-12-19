require_relative 'rmk'
require_relative 'vfile'
require_relative 'rule'
require_relative 'build'

class Rmk::VDir
	attr_reader :rmk, :abs_src_path, :abs_out_path
	attr_reader :srcfiles, :outfiles, :builds
	attr_reader :vars, :rules, :subdirs
	attr_reader :defaultfile

	# create virtual dir
	# @param rmk [Rmk] Rmk obj
	# @param parent [Rmk::VDir, nil] parent virtual dir, or nil for root
	# @param path [String] path relative to parent, or empty for root
	def initialize(rmk, parent, path = '')
		@rmk = rmk
		@parent = parent
		@defaultfile = @parent&.defaultfile
		@rules = {}
		@subdirs = {}
		@srcfiles = {}
		@outfiles = {}
		@builds = []
		@virtual_path = @parent&.join_virtual_path("#{path}/")
		Dir.mkdir @virtual_path if @virtual_path && !Dir.exist?(@virtual_path)
		@abs_src_path = ::File.join @rmk.srcroot, @virtual_path.to_s, ''
		@abs_out_path = ::File.join @rmk.outroot, @virtual_path.to_s, ''
		@vars = Rmk::Vars.new @rmk.vars
		define_system_vars
	end

	private def define_system_vars
		@vars['vpath'] = @virtual_path || '.'
		@vars['srcpath'] = @abs_src_path[0 .. -2]
		@vars['outpath'] = @abs_out_path[0 .. -2]
	end

	def vpath; @virtual_path end

	def include_subdir(path)
		@subdirs[path] ||= Rmk::VDir.new @rmk, self, path
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
		match = /^((?:[^\/*]+\/)*)([^\/*]*)(?:\*([^\/*]*))?$/.match pattern
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
		return @rmk.find_inputfiles pattern if pattern.match? /^[A-Z]:/
		pattern = Rmk.normalize_path pattern
		dir, regex = split_vpath_pattern pattern
		files = find_srcfiles_imp pattern
		files.concat find_outfiles_imp  dir, regex
		[files, regex]
	end

	# find srcfiles raw implement(assume all parms valid)
	# @param pattern [String] virtual path, can include '*' to match any char at last no dir part
	# @return [Array<Hash>]
	protected def find_srcfiles_imp(pattern)
		::Dir[join_abs_src_path pattern].map! do |fn|
			next @srcfiles[fn] if @srcfiles.include? fn
			@srcfiles[fn] = @rmk.add_src_file path: fn, vpath:fn[@rmk.srcroot.size + 1 .. -1]
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
	def find_outfiles(pattern)
		return @rmk.find_outfiles pattern if pattern.match? /^[A-Z]:/i
		find_outfiles_imp *split_vpath_pattern(pattern)
	end

	# add a output file
	# @param name file name, must relative to this dir
	# @return [VFile] virtual file object
	def add_out_file(name)
		@outfiles[name] = @rmk.add_out_file path:join_abs_out_path(name), vpath:join_virtual_path(name)
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

	def define_var(indent, name, append, value)
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
		last[:vars][name, append] = value
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
			raise "dir parse error: '#{file}' doesn't exist and can't finded any 'default.rmk'"
		end
	end

	def parse_file(file)
		last_state, @state = @state, [{indent:0, type:nil, condition:nil, vars:@vars}]
		lines = IO.readlines file
		markid = lid = 0
		while lid < lines.size
			line, markid = '', lid
			while lid < lines.size
				break if lines[lid].sub!(/(?<!\$)(?:\$\$)*\K#.*$/, '')
				break unless lines[lid].sub!(/(?<!\$)(?:\$\$)*\K\$\n/m, '')
				line += lines[lid]
				lid += 1
				lines[lid]&.lstrip!
			end
			parse_line lid < lines.size ? line + lines[lid] : line, markid
			lid += 1
		end
		@state = last_state
	rescue
		$!.set_backtrace $!.backtrace.push "#{file}:#{markid + 1}:vpath'#{@virtual_path}'"
		raise
	end

	def parse_line(line, lid)
		match = /^(?<indent> *|\t*)(?:(?<firstword>\w+)\s*(?<content>.+)?)?$/.match line
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
			parms = state[:vars].split_str line
			if logicmod
				raise 'must have two str' unless parms.size == 2
				value = logicnot ? parms[0] != parms[1] : parms[0] == parms[1]
			else
				raise 'must have var name' if parms.empty?
				value = logicnot ? !parms.any?{|vn| @vars.include? vn} : parms.all?{|vn| @vars.include? vn}
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
			rule = @rules[match[:name]] = Rmk::Rule.new state[:vars], command:match[:command]
			@state << {indent:indent, type: :AcceptVar, condition:state[:condition], vars:rule.vars}
		when /^build(each)?$/
			eachmode = Regexp.last_match 1
			state = begin_define_nonvar indent
			match = /^(?<rule>\w+)\s+(?<parms>.*)$/.match line
			raise 'syntax error' unless match
			raise "rule '#{match[:rule]}' undefined" unless @rules.include? match[:rule]
			parms = match[:parms].split /(?<!\$)(?:\$\$)*\K>>/
			raise "must have only one '>>' separator for separat input and output" if parms.size > 2
			ioregex = /(?<!\$)(?:\$\$)*\K&/
			iparms = parms[0].split ioregex
			raise 'input field count error' unless (1..3) === iparms.size
			if parms[1]
				oparms = parms[1].split ioregex
				raise 'output field count error' unless (1..2) === oparms.size
			else
				oparms = []
			end
			iparms[0] = state[:vars].split_str iparms[0]
			raise 'must have input file' if iparms[0].size == 0
			if eachmode
				vars = Rmk::MultiVarWriter.new
				iparms[0].each do |fn|
					files, regex = find_inputfiles fn
					files.each do |file|
						stem = regex && (file.vpath&.[](@virtual_path.size .. -1) || file.path)[regex, 1]
						build = Rmk::Build.new(self, @rules[match[:rule]], state[:vars], [file], iparms[1],
							iparms[2], oparms[0], oparms[1], stem:stem)
						@builds << build
						vars << build.vars
					end
				end
			else
				files = []
				iparms[0].each {|fn| files.concat find_inputfiles(fn)[0]}
				build = Rmk::Build.new(self, @rules[match[:rule]], state[:vars], files, iparms[1], iparms[2], oparms[0], oparms[1])
				@builds << build
				vars = build.vars
			end
			@state << {indent:indent, type: :AcceptVar, condition:state[:condition], vars:vars}
		when 'default'
			state = begin_define_nonvar indent
			parms = state[:vars].split_str line
			raise "must have file name" if parms.empty?
			parms.each do |parm|
				files = find_outfiles parm
				raise "pattern '#{parm}' not match any out file" if files.empty?
				@rmk.add_default *files
			end
		when 'include'
			state = begin_define_nonvar indent
			parms = state[:vars].split_str line
			raise "#{lid}: must have file name" if parms.empty?
			parms.each do |parm|
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
			parms = state[:vars].split_str line
			raise "#{lid}; must have dir name or matcher" if parms.empty?
			threads = []
			parms.each do |parm|
				dirs = ::Dir[::File.join @abs_src_path, parm, '']
				raise "subdir '#{parm}' doesn't exist" if dirs.empty? && !parm.match?(/(?<!\$)(?:\$\$)*\K\*/)
				dirs.each do |dir|
					dir = include_subdir dir[@abs_src_path.size .. -2]
					threads << Rmk::Schedule.new_thread!( &dir.method(:parse) )
				end
			end
			threads.each{|thr| thr.join}
		when 'inherit'
			begin_define_nonvar indent
			raise 'syntax error' if line
			if @parent
				@vars.merge! @parent.vars
				define_system_vars
				@rules.merge! @parent.rules
			end
		when 'error'
			state = begin_define_nonvar indent
			$stderr.puts state[:vars].interpolate_str line
			exit
		when 'warn'
			state = begin_define_nonvar indent
			$stderr.puts state[:vars].interpolate_str line
		when 'info'
			state = begin_define_nonvar indent
			puts state[:vars].interpolate_str line
		else
			match = /^(?:(?<append>\+=)|=)(?(<append>)|\s*)(?<value>.*)$/.match line
			raise 'syntax error' unless match
			define_var indent, firstword, match[:append], match[:value]
		end
	end
end
