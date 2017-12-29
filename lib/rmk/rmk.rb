require 'rmk/version'
require_relative 'vars'
require_relative 'storage'

class Rmk
	# normalize path, drive letter upcase and path seperator set to '/'
	# @param path [String]
	# @return [String]
	def self.normalize_path(path) path.gsub(?\\, ?/).sub(/^[a-z](?=:)/){|ch|ch.upcase} end

	# create Rmk object
	# @param srcroot [String] source root dir,can be absolute or relative to output root(start with ..)
	# @param outroot [String] output root dir,can be absolute or relative to pwd,default pwd
	def initialize(srcroot:'', outroot:'')
		@files_mutex = Thread::Mutex.new	# files operate mutex

		srcroot = Rmk.normalize_path srcroot
		@outroot = File.join Rmk.normalize_path(File.absolute_path outroot), ''
		@srcroot = File.join File.absolute_path(srcroot, @outroot), ''
		raise "source path '#{@srcroot}' not exist or not directory" unless ::Dir.exist?(@srcroot)
		warn 'in-source build' if @outroot == @srcroot
		@src_relative = srcroot.match?(/^\.\./) && File.join(srcroot, '')
		Dir.mkdir @outroot unless Dir.exist? @outroot
		Dir.chdir @outroot
		Dir.mkdir '.rmk' unless Dir.exist? '.rmk'
		@mid_storage = Rmk::Storage.new '.rmk/mid', {}
		@dep_storage = Rmk::Storage.new '.rmk/dep', {}
		@src_list_storage = Rmk::Storage.new '.rmk/src', {}
		@srcfiles = {}
		@outfiles = {}
		@defaultfiles = []
		@vars = {'srcroot'=>@srcroot[0..-2], 'outroot'=>@outroot[0..-2], 'src_rto_root'=>(@src_relative || @srcroot)[0..-2]}.freeze
		@virtual_root = Rmk::VDir.new self, nil
	end
	attr_reader :srcroot, :outroot, :vars, :virtual_root, :srcfiles, :outfiles
	attr_reader :mid_storage, :dep_storage, :src_list_storage

	def join_abs_src_path(path) File.join @srcroot, path end

	# join src file path relative to out root, or absolute src path when not relative src
	def join_rto_src_path(path) ::File.join @src_relative ? @src_relative : @srcroot, path end

	# split path pattern to dir part and file match regex part
	# @param pattern [String] absolute path, can include '*' to match any char at last no dir part
	# when pattern include '*', return [dir part, file(or dir) match regex, post dir part, post file part]
	# ;otherwise return [origin pattern, nil, nil, nil]
	def split_path_pattern(pattern)
		match = /^([a-zA-Z]:\/(?:[^\/*]+\/)*+)([^\/*]*+)(?:\*([^\/*]*+))?(?(3)(\/(?:[^\/*]+\/)*+[^\/*]++)?)$/.match pattern
		raise "file syntax '#{pattern}' error" unless match
		dir, prefix, postfix, postpath = *match[1..5]
		regex = postfix && /#{Regexp.escape prefix}(.*)#{Regexp.escape postfix}$/
		[regex ? dir : pattern, regex, postpath]
	end

	# find files which can be build's imput file
	# @param pattern [String] absolute path to find src and out files which can include '*' to match any char at last no dir part
	# @param ffile [Boolean] return FFile struct or not
	# @return [Array<VFile, FFile>] return array of FFile when ffile, otherwise array of VFile
	def find_inputfiles(pattern, ffile:false)
		pattern = Rmk.normalize_path pattern
		path, regex, postpath = split_path_pattern pattern
		files = []
		if regex
			@files_mutex.synchronize do
				find_outfiles_imp files, path, regex, postpath, ffile:ffile
				range = postpath ? path.size..-1-postpath.size : path.size..-1
				Dir[pattern].each do |fn|
					next if @outfiles.include? fn
					next files << (ffile ? FFile.new(@srcfiles[fn], nil, fn[range][regex, 1]) : @srcfiles[fn]) if @srcfiles.include? fn
					file = (@srcfiles[fn] = VFile.new rmk:self, path:fn, is_src:true,
						vpath:fn.start_with?(@srcroot) && fn[@srcroot.size .. -1])
					files << (ffile ? FFile.new(file, nil, fn[range][regex, 1]) : file)
				end
			end
		else
			files << @files_mutex.synchronize do
				next ffile ? FFile.new(@outfiles[path]) : @outfiles[path] if @outfiles.include? path
				next ffile ? FFile.new(@srcfiles[path]) : @srcfiles[path] if @srcfiles.include? path
				next unless File.exist? path
				file = @srcfiles[path] = VFile.new rmk:self, path:path, is_src:true,
						vpath:path.start_with?(@srcroot) && path[@srcroot.size .. -1]
				ffile ? FFile.new(file) : file
			end
		end
		files
	end

	# find files which must be build's output
	# @param pattern [String] absolute path to find out files which can include '*' to match any char at last no dir part
	# @return [Array<Hash>] return Array of file, and Regex when has '*' pattern
	def find_outfiles(pattern)
		path, regex, postpath = split_path_pattern Rmk.normalize_path pattern
		files = []
		@files_mutex.synchronize do
			next (files << @outfiles[path] if @outfiles.include? path) unless regex
			find_outfiles_imp files, path, regex, postpath
		end
		files
	end

	# find outfiles raw implement(assume all parms valid)
	# @param files [Array<VFile>] array to store finded files
	# @param path [String] absolute path, path must be dir(end with '/') or empty
	# @param regex [Regexp] file match regexp, or dir match regexp when postpath not nil
	# @param postpath [String, nil] path after dir match regexp
	# @param ffile [Boolean] return FFile struct or not
	# @return [Array<VFile, FFile>] return array of FFile when ffile, otherwise array of VFile
	private def find_outfiles_imp(files, path, regex, postpath, ffile:false)
		range = postpath ? path.size..-1-postpath.size : path.size..-1
		return @outfiles.each do |k, v|
			next unless k.start_with?(path) && k[range].match?(regex)
			files << (ffile ? FFile.new(v, nil, k[range][regex, 1]) : v)
		end unless postpath
		@outfiles.each do |k, v|
			next unless k.start_with?(path) && k.end_with?(postpath) && k[range].match?(regex)
			files << (ffile ? FFile.new(v, nil, k[range][regex, 1]) : v)
		end
	end

	# register a out file
	# @param path [String]
	# @param vpath [String]
	# @return [Rmk::VFile] return file obj added
	def add_out_file(path:, vpath:nil)
		@files_mutex.synchronize do
			raise "file '#{path}' has been defined" if @outfiles.include? path
			file = @srcfiles.delete(path).change_to_out! file if @srcfiles.include? path
			@outfiles[path] = VFile.new rmk:self, path:path, vpath:vpath
		end
	end

	# register a src file
	# @param path [String]
	# @param vpath [String]
	# @return [Rmk::VFile] return file obj added
	def add_src_file(path:, vpath:nil)
		@files_mutex.synchronize do
			@outfiles[path] || (@srcfiles[path] ||= VFile.new(rmk:self, path:path, vpath:vpath, is_src:true))
		end
	end

	# add default target
	def add_default(*files) @files_mutex.synchronize{@defaultfiles.concat files} end

	# parse project
	# @return [self]
	def parse
		puts 'Rmk: parse start'
		@virtual_root.parse
		@dep_storage.wait_ready
		@dep_storage.data!.each do |path, fns|
			next warn "Rmk: warn: outfile '#{path}' not found when restore depfile" unless @outfiles.include? path
			build = @outfiles[path].output_ref_build
			fns.each do |fn|
				files = @virtual_root.find_inputfiles fn
				files.each{|file| file.input_ref_builds << build; build.infiles << file}
			end
		end
		puts 'Rmk: parse done'
		self
	end

	def build(*tgts)
		puts 'Rmk: build start'
		@mid_storage.wait_ready
		if tgts.empty?
			files = @defaultfiles
		else
			files = tgts.map do |name|
				file = Rmk.normalize_path name
				file = @outfiles[File.absolute_path file, @outroot] || @srcfiles[File.absolute_path file, @srcroot]
				raise "build target '#{name}' not found" unless file
				file = file.input_ref_builds[0].outfiles[0] if file.src? && file.input_ref_builds.size == 1
				file
			end
		end
		@src_list_storage.wait_ready
		@src_list_storage.data!.each do |src, outs|
			next if @srcfiles.include? src
			outs.each{|file| File.delete file rescue nil}
		end
		@src_list_storage.data!.clear
		Rmk::Schedule.new_thread! do
			@srcfiles.each_value do |src|
				outs = []
				action = proc{|build| build.outfiles.each{|out| outs << (out.vpath || out.path)}}
				src.input_ref_builds.each &action
				src.order_ref_builds.each &action
				@src_list_storage[src.path] = outs
			end
		end
		if files.empty?
			@srcfiles.each_value{|file| file.check_for_build}
		else
			checklist = []
			checkproc = proc do |fi|
				next checklist << fi if fi.src?
				fi.output_ref_build.infiles.each &checkproc
				fi.output_ref_build.orderfiles.each &checkproc
			end
			files.each &checkproc
			exit puts('found nothing to build') || 0 if checklist.empty?
			checklist.each {|file| file.check_for_build}
		end
		while Thread.list.size > 1
			thr = Thread.list[-1]
			thr.join unless thr == Thread.current
		end
		puts 'Rmk: build end'
		@mid_storage.data!.each_key {|key| @mid_storage.data!.delete key unless @src_list_storage.data!.include? key}
		@mid_storage.save
		@dep_storage.data!.each_key {|key| @dep_storage.data!.delete key unless @outfiles.include? key}
		@dep_storage.save
		@src_list_storage.save
	end

	class VFile; end
end
