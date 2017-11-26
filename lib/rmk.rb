require 'rmk/version'

class Rmk
	def self.normalize_path(path) path.gsub(?\\, ?/).sub(/^[a-z](?=:)/){|ch|ch.upcase} end

	# split parms using un-escape space as separator
	def self.split_parms(line)
		result = []
		until line.empty?
			head, match, line = line.partition /(?<!\$)((?:\$\$)*)\s+/
			break result << head if match.empty?
			result << head + $1 unless head.empty? && $1.empty?
		end
		result
	end

	def initialize(srcroot, outroot)
		@rootdir = Rmk::Dir.new Rmk.normalize_path(srcroot), Rmk.normalize_path(outroot)
		::Dir.mkdir outroot unless Dir.exist? outroot
		@rootdir.parse
	end

	def build(*tgts)
	end
end

class Rmk::Rule
	attr_accessor :vars
	def initialize
		vars = {}
	end
end

class Rmk::Dir
	attr_reader :srcroot, :outroot, :path, :full_src_path, :full_out_path
	attr_reader :srcfiles, :outfiles
	attr_reader :vars, :rules, :subdirs
	attr_writer :defaultfile
	protected :defaultfile=

	def initialize(srcroot, outroot, path = '')
		@srcroot, @outroot, @path, @defaultfile = srcroot, outroot, path, nil
		@vars, @rules, @subdirs = {}, {}, {}
		@srcfiles, @outfiles = [], []
		@full_src_path = ::File.join @srcroot, @path, ''
		@full_out_path = ::File.join @outroot, @path, ''
	end

	def add_subdir(path)
		return @subdirs[path] if @subdirs.include? path
		dir = @subdirs[path] = Rmk::Dir.new @srcroot, @outroot, path
		dir.defaultfile = @defaultfile
		dir
	end

	def preprocess_str(str) str.gsub(/\$((?:\$\$)*){(\w+)}/){"#{$1}#{@vars[$2]}"} end

	def unescape_str(str) str.gsub(/\$(?:([\$\s])|(\w+))/) {$1 || @vars[$2].to_s} end

	def join_src_path(file) ::File.join @full_src_path, file end

	def join_out_path(file) ::File.join @full_out_path, file end

	private def begin_define_nonvar(indent)
		last = @state[-1]
		if !last[:subindent]			# general context
			raise 'invalid indent' unless indent == last[:indent]
		elsif last[:subindent] == :var	# rule or build context which can add var
			@state.pop
			last = @state[-1]
			raise 'invalid indent' unless indent == last[:indent]
		else					# just after condition context
			raise 'invalid indent' unless indent > last[:indent]
			@state << {indent:indent, subindent:nil, condition:last[:condition], vars:last[:vars]}
			last = @state[-1]
		end
		last
	end

	private def end_last_define
		last = @state[-1]
		@state.pop if last[:subindent] == :var
	end

	def define_var(indent, name, value)
		last = @state[-1]
		if !last[:subindent]			# general context
			raise 'invalid indent' unless indent == last[:indent]
		elsif last[:subindent] == :var	# rule or build context which can add var
			raise 'invalid indent' if indent < last[:indent]
			if indent > last[:indent]
				@state << {indent:indent, subindent:nil, condition:last[:condition], vars:last[:vars]}
				last = @state[-1]
			else
				@state.pop
				last = @state[-1]
				raise 'invalid indent' unless indent == last[:indent]
			end
		else					# just after condition context
			raise 'invalid indent' unless indent > last[:indent]
			@state << {indent:indent, subindent:nil, condition:last[:condition], vars:last[:vars]}
			last = @state[-1]
		end
		last[:vars][name] = value
	end

	def parse
		raise "dir '#{@full_src_path}' has been parsed" if @state
		@state = []
		file = join_src_path 'default.rmk'
		@defaultfile = file if ::File.exist? file
		file = join_out_path 'config.rmk'
		parse_file file if ::File.exist? file
		file = join_src_path 'dir.rmk'
		if ::File.exist? file
			parse_file file
		elsif @defaultfile
			parse_file @defaultfile
		else
			raise "dir parse error: '#{file}' doesn't exist and can't finded any 'default.mk'"
		end
	end

	def parse_file(file)
		last_state, @state = @state, [{indent:0, subindent:nil, condition:nil, vars:@vars}]
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
		match = /^(?<indent>\s*)(?:(?<firstword>\w+)(?:\s*|\s+(?<content>.*)))?$/.match line
		raise 'syntax error' unless match
		indent, firstword, line = match[:indent].size, match[:firstword], match[:content]
		return end_last_define unless firstword
		state = @state[-1]
		if !state[:condition].nil? && !state[:condition]
			case firstword
			when /^ifn?(?:eq|def)$/
				raise 'invalid indent' unless indent > last[:indent]
				@state << {indent:indent, subindent: :condition, condition:false, vars:last[:vars]}
			when 'else'
				raise 'syntax error' unless line.match? /^\s*$/
				raise 'invalid indent' unless indent == last[:indent]
				last[:condition] = true
			when 'endif'
				raise 'syntax error' unless line.match? /^\s*$/
				raise 'invalid indent' unless indent == last[:indent]
				@state.pop
			end
			return
		end
		case firstword
		when /^if(n)?eq$/
			value = false
			state = begin_define_nonvar indent
			@state << {indent:indent, subindent: :condition, condition:value, vars:state[:vars]}
		when /^if(n)?def$/
			value = false
			state = begin_define_nonvar indent
			@state << {indent:indent, subindent: :condition, condition:value, vars:state[:vars]}
		when 'else'
			raise 'syntax error' unless line.match? /^\s*$/
			while state
				raise 'not if condition' if state[:condition].nil?
				if state[:subindent]&.== :condition
					raise 'invalid indent' unless indent == state[:indent]
					return state[:condition] = false
				end
				@state.pop
				state = @state[-1]
			end
		when 'endif'
			raise 'syntax error' unless line.match? /^\s*$/
			while state
				raise 'not if condition' if state[:condition].nil?
				if state[:subindent]&.== :condition
					raise 'invalid indent' unless indent == state[:indent]
					return @state.pop
				end
				@state.pop
				state = @state[-1]
			end
			raise 'not found match if'
		when 'rule'
			raise 'rule name or command invalid' unless line =~ /^\s+(?<name>\w+)\s*(?:=\s*(?<command>.*))?$/
			state = begin_define_nonvar indent
			raise "rule '#{name}' has been defined" if @rules.include? name
			rule = @rules[name] = {'$command'=>command}
			@state << {indent:indent, subindent: :var, condition:state[:condition], vars:rule}
		when 'buildeach'
		when 'build'
		when 'default'
		when 'include'
			parms = Rmk.split_parms preprocess_str line
			raise "#{lid}: must have file name" if parms.empty?
			parms.each do |parm|
				if parm.match? /^[a-zA-Z]:/
					raise "file '#{parm}' not exist" unless ::File.exist? parm
					parse_file parm
				else
					file = join_out_path parm
					next parse_file file if ::File.exist? file
					file = join_src_path parm
					next parse_file file if ::File.exist? file
					raise "file '#{parm}' not exist"
				end
			end
		when 'incdir'
			parms = Rmk.split_parms preprocess_str line
			raise "#{lid}; must have dir name or matcher" if parms.empty?
			parms.each do |parm|
				parm = unescape_str parm
				dirs = ::Dir[::File.join @full_src_path, parm, '']
				raise "#{lid}: subdir '#{parm}' doesn't exist" if dirs.empty?
				dirs.each do |dir|
					dir = add_subdir dir.sub @full_src_path, ''
					new_thread {dir.parse}
				end
			end
			join_threads
		else
			match = /^\s*=\s*(?<value>.*)$/.match line
			raise "#{lid} : Óï·¨´íÎó" unless match
			define_var indent, firstword,(unescape_str preprocess_str match[:value])
		end
	end

	# run in new thread
	# @note not ready
	def new_thread(&cmd) cmd.call end

	# wait all threads
	# @note not ready
	def join_threads; end
end
