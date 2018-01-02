require_relative 'rmk'
require_relative 'vfile'
require_relative 'rule'
require_relative 'build'

class Rmk::VOutDir < Hash
	attr_reader :path, :vpath

	def initialize(path:, vpath:nil)
		super()
		@path, @vpath = path, vpath
	end

	def derive_new(subname)
		Rmk::VOutDir.new path:File.join(@path, subname, ''), vpath:@vpath && File.join(@vpath, subname, '')
	end

	def join_abs_path(path) File.join @path, path end

	def join_virtual_path(path) @vpath && File.join(@vpath, path) end

	def new_filepath(name)
		{path:File.join(@path, name), vpath:@vpath && (@vpath.empty? ? name : File.join(@vpath, name))}
	end
end

class Rmk::VDir
	attr_reader :rmk, :abs_src_path, :abs_out_path
	attr_reader :srcfiles, :outfiles, :voutfiles, :builds
	attr_reader :vars, :rules, :subdirs
	attr_reader :defaultfile

	# create virtual dir
	# @param rmk [Rmk] Rmk obj
	# @param parent [Rmk::VDir, nil] parent virtual dir, or nil for root
	# @param path [String] path relative to parent, or empty for root
	def initialize(rmk, parent, path = '')
		@rmk = rmk
		@parent = parent
		@name = path
		@defaultfile = @parent&.defaultfile
		@rules = {}
		@subdirs = {}
		@srcfiles = {}
		@builds = []
		@collections = {}
		@virtual_path = @parent&.join_virtual_path("#{@name}/")
		Dir.mkdir @virtual_path if @virtual_path && !Dir.exist?(@virtual_path)
		@abs_src_path = ::File.join @rmk.srcroot, @virtual_path.to_s, ''
		@abs_out_path = ::File.join @rmk.outroot, @virtual_path.to_s, ''
		@outfiles = Rmk::VOutDir.new path:@abs_out_path, vpath:@virtual_path || ''
		@voutfiles = {''=>@outfiles}
		@vars = Rmk::Vars.new @rmk.vars.clone(freeze:false), nil
		@vars.rmk['vpath'] = @virtual_path&.[](0 .. -2) || '.'
		@vars.rmk['srcpath'] = @abs_src_path[0 .. -2]
		@vars.rmk['outpath'] = @abs_out_path[0 .. -2]
	end

	def vpath; @virtual_path end

	def collections(name = nil) name ? @collections[name] ||= [] : @collections end

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
	# @return [Array(String, <Regex, nil>, <String, nil>, <String, nil>)]
	# when pattern include '*', return [dir part, file(or dir) match regex, post dir part, post file part]
	# ;otherwise return [origin pattern, nil, nil, nil]
	def split_vpath_pattern(pattern)
		match = /^((?:[^\/*]+\/)*+)([^\/*]*+)(?:\*([^\/*]*+))?(?(3)(\/(?:[^\/*]+\/)*+[^\/*]++)?)$/.match pattern
		raise "file syntax '#{pattern}' error" unless match
		dir, prefix, postfix, postpath = *match[1..4]
		regex = postfix && /#{Regexp.escape prefix}(.*)#{Regexp.escape postfix}$/
		[regex ? dir : pattern, regex, postpath]
	end

	# find files which can be build's imput file
	# @param pattern [String] virtual path to find src and out files which can include '*' to match any char at last no dir part
	# ;or absolute path to find a src file which not in src tree
	# @param ffile [Boolean] return FFile struct or not
	# @return [Array<VFile, FFile>] return array of FFile when ffile, otherwise array of VFile
	def find_inputfiles(pattern, ffile:false)
		return @rmk.find_inputfiles pattern, ffile:ffile if pattern.match? /^[A-Z]:/
		pattern = Rmk.normalize_path pattern
		dir, regex, postpath = split_vpath_pattern pattern
		return find_voutfiles_imp dir, regex, postpath, ffile:ffile if pattern.start_with? ':'
		files = find_srcfiles_imp pattern, dir, regex, postpath, ffile:ffile
		files.concat find_outfiles_imp  dir, regex, postpath, ffile:ffile
		files
	end

	# find srcfiles raw implement(assume all parms valid)
	# @param pattern [String] virtual path, can include '*' to match any char at last no dir part
	# @param ffile [Boolean] return FFile struct or not
	# @return [Array<VFile, FFile>] return array of FFile when ffile, otherwise array of VFile
	protected def find_srcfiles_imp(pattern, dir, regex, postpath, ffile:false)
		return Dir[join_virtual_path(pattern), base: @rmk.srcroot].map! do |vp|
			@rmk.add_src_file path:@rmk.join_abs_src_path(vp), vpath:vp
		end unless ffile
		return Dir[pattern, base:@abs_src_path].map! do |vn|
			FFile.new @rmk.add_src_file(path:join_abs_src_path(vn), vpath:join_virtual_path(vn)), vn, nil
		end unless regex
		range = dir.size .. (postpath ? -1 - postpath.size : -1)
		Dir[pattern, base:@abs_src_path].map! do |vn|
			file = @rmk.add_src_file path:join_abs_src_path(vn), vpath:join_virtual_path(vn)
			FFile.new file, vn, vn[range][regex, 1]
		end
	end

	# find outfiles raw implement(assume all parms valid)
	# @param path [String] virtual path, if regex, path must be dir(end with '/') or empty, otherwise contrary
	# @param regex [Regexp, nil] if not nil, file match regexp, or dir match regexp when postpath not nil
	# @param postpath [String, nil] path after dir match regexp
	# @param ffile [Boolean] return FFile struct or not
	# @return [Array<VFile, FFile>] return array of FFile when ffile, otherwise array of VFile
	protected def find_outfiles_imp(path, regex, postpath, ffile:false)
		files = []
		unless regex
			*spath, fn = *path.split('/')
			dir = spath.inject(self){|obj, dn| obj&.subdirs&.[](dn)}
			return files unless dir
			dir.voutfiles.each_value{|ofs| files << (ffile ? FFile.new(ofs[fn], path) : ofs[fn]) if ofs.include? fn}
			files.concat ffile ? dir.collections[fn].map{|f| FFile.new f} : dir.collections[fn] if dir.collections.include? fn
			return files
		end
		dir = path.split('/').inject(self){|obj, dn| obj&.subdirs&.[](dn)}
		return files unless dir
		if postpath
			*spath, fn = *postpath.delete_prefix('/').split('/')
			dir.subdirs.each do |name, obj|
				next unless name.match? regex
				sdir = spath.inject(obj){|sobj, dn| sobj&.subdirs[dn]}
				next unless sdir
				vname, stem = path + name + postpath, name[regex, 1] if ffile
				sdir.voutfiles.each_value{|ofs| files << (ffile ? FFile.new(ofs[fn], vname, stem) : ofs[fn]) if ofs.include? fn}
				files.concat ffile ? sdir.collections[fn].map{|f| FFile.new f} : sdir.collections[fn] if sdir.collections.include? fn
			end
		else
			dir.voutfiles.each_value do |ofs|
				ofs.each {|k, v| files << (ffile ? FFile.new(v, path + k, k[regex, 1]) : v) if k.match? regex}
			end
			dir.collections.each do |k, v|
				next unless k.match? regex
				files.concat ffile ? v.map {|f| FFile.new f} : v
			end
		end
		files
	end

	# find voutfiles
	protected def find_voutfiles_imp(path, regex, postpath, ffile:false)
		files = []
		path.delete_prefix! ':'
		unless regex
			match = path.match /^(.*)\/([^\/]+)$/
			vout, name = match[1], match[2]
			raise "vout dir '#{vout}' not found" unless @voutfiles.include? vout
			vout = @voutfiles[vout]
			return files unless vout.include? name
			files << (ffile ? FFile.new(vout[name], name) : vout[name])
			return files
		end
		if postpath
			match = postpath.match /^(.*)\/([^\/]+)$/
			postpath, name = match[1], match[2]
			range = path.size .. -1-postpath.size
			@voutfiles.each do |vn, fs|
				next unless vn.start_with?(path) && vn.end_with?(postpath) && vn[range].match?(regex) && fs.include?(name)
				files << (ffile ? FFile.new(fs[name], name, vn[range][regex, 1]) : fs[name])
			end
		else
			vout = path.delete_suffix '/'
			raise "vout dir '#{vout}' not found" unless @voutfiles.include? vout
			vout = @voutfiles[vout]
			vout.each {|name, file| files << (ffile ? FFile.new(file, name, name[regex, 1]) : file) if name.match? regex}
		end
		files
	end

	# find files which must be build's output
	# @param pattern [String] virtual path to find out files which can include '*' to match any char at last no dir part
	# @return [Array<Hash>] return Array of file, and Regex when has '*' pattern
	def find_outfiles(pattern)
		return @rmk.find_outfiles pattern if pattern.match? /^[A-Z]:/i
		return find_voutfiles_imp *split_vpath_pattern(pattern) if pattern.start_with? ':'
		find_outfiles_imp *split_vpath_pattern(pattern)
	end

	# add a output file
	# @param name file name, relative to this dir when not absolute path
	# @return [VFile] virtual file object
	def add_out_file(name)
		if /^[A-Z]:/.match? name
			@rmk.add_out_file path:name, vpath: name.start_with?(@rmk.outroot) && name[@rmk.outroot.size .. - 1]
		elsif /^:(.*)\/([^\/]+)$/.match name
			vout, name = $1, $2
			raise "vout dir '#{vout}' not found" unless @voutfiles.include? vout
			@voutfiles[vout][name] = @rmk.add_out_file **@voutfiles[vout].new_filepath(name)
		else
			@voutfiles[''][name] = @rmk.add_out_file path:join_abs_out_path(name), vpath:join_virtual_path(name)
		end
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
			rule = @rules[match[:name]] = Rmk::Rule.new match[:command]
			@state << {indent:indent, type: :AcceptVar, condition:state[:condition], vars:rule.vars}
		when /^exec$/
			state = begin_define_nonvar indent
			match = /^(?<rule>\w+)(?<each>\s+each)?:\s*(?<parms>.*)$/.match line
			raise 'syntax error' unless match
			raise "rule '#{match[:rule]}' undefined" unless @rules.include? match[:rule]
			eachmode = match[:each]
			parms = match[:parms].split /(?<!\$)(?:\$\$)*\K>>/, -1
			raise "syntax error, use '>>' to separat input and output and collect" unless (1 .. 3) === parms.size
			ioregex = /(?<!\$)(?:\$\$)*\K&/
			iparms = parms[0].split ioregex
			raise 'input field count error' unless (1..3) === iparms.size
			if parms[1] && !parms[1].empty?
				oparms = parms[1].lstrip.split ioregex
				raise 'output field count error' unless (1..2) === oparms.size
			else
				raise 'syntax error: must give output field after >>' if parms[1] && !parms[2]
				oparms = []
			end
			if parms[2]
				parms[2] = state[:vars].split_str(parms[2].lstrip).map!{|name| collections name}
				raise 'must give collection name' if parms[2].empty?
			else
				parms[2] = @rules[match[:rule]]['collection']&.lstrip
				parms[2] = state[:vars].split_str(parms[2]).map!{|name| collections name} if parms[2]
			end
			iparms[0] = state[:vars].split_str iparms[0]
			raise 'must have input file' if iparms[0].size == 0
			if eachmode
				vars = Rmk::MultiVarWriter.new
				iparms[0].each do |fn|
					files = find_inputfiles fn, ffile:true
					files.each do |file|
						build = Rmk::Build.new(self, @rules[match[:rule]], state[:vars], [file], iparms[1],
							iparms[2], oparms[0], oparms[1], parms[2])
						@builds << build
						vars << build.vars
					end
				end
			else
				files = []
				iparms[0].each {|fn| files.concat find_inputfiles fn}
				build = Rmk::Build.new(self, @rules[match[:rule]], state[:vars], files, iparms[1], iparms[2],
					oparms[0], oparms[1], parms[2])
				@builds << build
				vars = build.vars
			end
			@state << {indent:indent, type: :AcceptVar, condition:state[:condition], vars:vars}
		when 'collect'
			state = begin_define_nonvar indent
			parms = line.split /(?<!\$)(?:\$\$)*\K>>/
			raise "must have only one '>>' separator for separat input and output" unless parms.size == 2
			collection = state[:vars].split_str(parms[1].lstrip).map!{|name| collections name}
			raise 'must give collection name' if collection.empty?
			state[:vars].split_str(parms[0]).each do |fn|
				files = find_inputfiles fn
				collection.each{|col| col.concat files}
			end
		when 'default'
			state = begin_define_nonvar indent
			parms = state[:vars].split_str line
			raise "must have file name" if parms.empty?
			parms.each do |parm|
				files = find_outfiles parm
				raise "pattern '#{parm}' not match any out file" if files.empty?
				@rmk.add_default *files
			end
		when /^include(_dir)?(_force)?$/
			dirmode, force = Regexp.last_match(1), Regexp.last_match(2)
			state = begin_define_nonvar indent
			parms = state[:vars].split_str line
			raise dirmode ? "must have file name" : "must have dir name or matcher" if parms.empty?
			if dirmode
				threads = []
				parms.each do |parm|
					dirs = Dir[File.join @abs_src_path, parm, '']
					if dirs.empty?
						raise "subdir '#{parm}' doesn't exist" if force
					else
						dirs.each do |dir|
							dir = include_subdir dir[@abs_src_path.size .. -2]
							threads << Rmk::Schedule.new_thread!( &dir.method(:parse) )
						end
					end
				end
				threads.each{|thr| thr.join}
			else
				parms.each do |parm|
					if parm.match? /^[a-zA-Z]:/
						if File.exist? parm
							parse_file parm
						else
							raise "file '#{parm}' not exist" if force
						end
					else
						files = find_outfiles parm
						if files.empty?
							file = join_abs_out_path parm
							next parse_file file if File.exist? file
							file = join_abs_src_path parm
							next parse_file file if File.exist? file
							raise "file '#{parm}' not exist" if force
						else
							files.each{|file| file.output_ref_build.parser_force_run!}
							files.each{|file| parse_file file.vpath}
						end
					end
				end
			end
		when 'vout'
			state = begin_define_nonvar indent
			match = line.match /^(\S+)\s*(?:=\s*(\S*)\s*)?$/
			raise 'syntax error' unless match
			if match[2]
				path = state[:vars].interpolate_str match[2]
				path << '/' unless path.end_with? '/'
				if path.match? /^[a-z]:\//i
					@voutfiles[match[1]] = Rmk::VOutDir.new path:path,
						vpath:path.start_with?(@rmk.outroot) && path[@rmk.outroot.size..-1]
				else
					path = join_virtual_path path
					@voutfiles[match[1]] = Rmk::VOutDir.new path:join_abs_out_path(path), vpath:path
				end
				Dir.mkdir path unless Dir.exist? path
				@vars.rmk[match[1] + '_path'] = @voutfiles[match[1]].path[0 .. -2]
			elsif @parent&.voutfiles&.include? match[1]
				path = (@voutfiles[match[1]] = @parent.voutfiles[match[1]].derive_new @name).path
				Dir.mkdir path unless Dir.exist? path
				@vars.rmk[match[1] + '_path'] = @voutfiles[match[1]].path[0 .. -2]
			else
				raise 'no inheritable vout dir'
			end
		when 'inherit'
			begin_define_nonvar indent
			raise 'syntax error' if line
			if @parent
				@vars.merge! @parent.vars
				@rules.merge! @parent.rules
			end
		when 'report'
			state = begin_define_nonvar indent
			parms = line.match /^((error)|warn|(info))\s+(.*)$/
			raise 'syntax error' unless parms
			line = "Rmk: #{parms[1]}: " + state[:vars].interpolate_str(parms[4])
			parms[3] ? puts(line) : $stderr.puts(line)
			exit 2 if parms[2]
		else
			match = /^(?:(?<append>\+=)|=)(?(<append>)|\s*)(?<value>.*)$/.match line
			raise 'syntax error' unless match
			define_var indent, firstword, match[:append], match[:value]
		end
	end
end
