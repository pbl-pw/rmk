require 'rmk/version'

class Rmk
	def self.normalize_path(path) path.gsub(?\\, ?/).sub(/^[a-z](?=:)/){|ch|ch.upcase} end

	# split parms using un-escape space as separator
	def self.split_parms(line, sep = '\s+')
		result = []
		until line.empty?
			head, match, line = line.partition /(?<!\$)((?:\$\$)*)#{sep}/
			break result << head if match.empty?
			result << head + $1 unless head.empty? && $1.empty?
		end
		result
	end

	def initialize(srcroot, outroot)
		@rootdir = Rmk::Dir.new self, Rmk.normalize_path(srcroot), Rmk.normalize_path(outroot)
		::Dir.mkdir outroot unless Dir.exist? outroot
		@rootdir.parse
	end

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

	def preprocess_str(str) str.gsub(/\$((?:\$\$)*){(\w+)}/){"#{$1}#{self[$2]}"} end

	def unescape_str(str) str.gsub(/\$(?:([\$\s>&])|(\w+))/){$1 || self[$2]} end
end

class Rmk::Build
	attr_reader :dir, :rule
	attr_reader :infiles, :orderfiles, :outfiles
	attr_reader :vars

	# create Build
	# @param dir [Rmk::Dir] build's dir
	# @param vars [Rmk::Vars] build's upstream of share vars, when define 'buildeach' it's share vars, otherwise it's rule's vars
	def initialize(dir, vars, input, implicit_input, order_only_input, output, implicit_output)
		@dir, @vars = dir, Rmk::Vars.new(vars)
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
		cmd = @vars['$command']
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
	attr_reader :rmk, :srcroot, :outroot, :path, :full_src_path, :full_out_path
	attr_reader :srcfiles, :outfiles, :builds
	attr_reader :vars, :rules, :subdirs
	attr_writer :defaultfile
	protected :defaultfile=

	def initialize(rmk, srcroot, outroot, path = '')
		@rmk, @srcroot, @outroot, @path, @defaultfile = rmk, srcroot, outroot, path, nil
		@vars, @rules, @subdirs = Rmk::Vars.new(nil), {}, {}
		@srcfiles, @outfiles, @builds = {}, {}, []
		@full_src_path = ::File.join @srcroot, @path, ''
		@full_out_path = ::File.join @outroot, @path, ''
	end

	def include_subdir(path)
		return @subdirs[path] if @subdirs.include? path
		dir = @subdirs[path] = Rmk::Dir.new @rmk, @srcroot, @outroot, path
		dir.defaultfile = @defaultfile
		dir
	end

	def join_src_path(file) ::File.join @full_src_path, file end

	def join_out_path(file) ::File.join @full_out_path, file end

	# add a output file
	# @param name file name, must relative to this dir
	def add_out_file(build, name)
		name = unescape_str name
		rpath = @path.empty? ? name : ::File.join(@path, name)
		@outfiles[name] = {ibuild:build, path:rpath, state: :parsed}
	end

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
			value = Regexp.last_match(1)
			state = begin_define_nonvar indent
			parms = Rmk.split_parms state[:vars].preprocess_str line
			raise 'must have two str' unless parms.size == 2
			value = value ? parms[0] != parms[1] : parms[0] == parms[1]
			@state << {indent:indent, subindent: :condition, condition:value, vars:state[:vars]}
		when /^if(n)?def$/
			value = Regexp.last_match(1)
			state = begin_define_nonvar indent
			parms = Rmk.split_parms state[:vars].preprocess_str line
			raise 'must have var name' if parms.empty?
			value = value ? parms.all{|parm| !@vars.include? state[:vars].unescape_str parm} :
				parms.all{|parm| @vars.include? state[:vars].unescape_str parm}
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
			rule = @rules[name] = Rmk::Rule.new @vars, '$command'=>command
			@state << {indent:indent, subindent: :var, condition:state[:condition], vars:rule}
		when /^build(each)?$/
			eachmode = $1
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
			iparms.map!{|fns| Rmk.split_parms state[:vars].preprocess_str fns}
			oparms.map!{|fns| Rmk.split_parms state[:vars].preprocess_str fns}
			if eachmode
				vars = {}
			else
				@builds << Rmk::Build.new(self, match[:rule], iparms[0], iparms[1], iparms[2], oparms[0], oparms[1]).bind_vars(vars)
				vars = @builds[-1].vars
			end
			@state << {indent:indent, subindent: :var, condition:state[:condition], vars:vars}
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
					file = join_out_path parm
					next parse_file file if ::File.exist? file
					file = join_src_path parm
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
				dirs = ::Dir[::File.join @full_src_path, parm, '']
				raise "#{lid}: subdir '#{parm}' doesn't exist" if dirs.empty?
				dirs.each do |dir|
					dir = include_subdir dir.sub @full_src_path, ''
					new_thread {dir.parse}
				end
			end
			join_threads
		else
			match = /^\s*=\s*(?<value>.*)$/.match line
			raise "#{lid} : Óï·¨´íÎó" unless match
			define_var indent, firstword,(state[:vars].unescape_str state[:vars].preprocess_str match[:value])
		end
	end

	# run in new thread
	# @note not ready
	def new_thread(&cmd) cmd.call end

	# wait all threads
	# @note not ready
	def join_threads; end
end
