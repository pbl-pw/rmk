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

		@srcroot = Rmk.normalize_path(::File.absolute_path srcroot, outroot)
		raise "source path '#{@srcroot}' not exist or not directory" unless ::Dir.exist?(@srcroot)
		@outroot = Rmk.normalize_path(::File.absolute_path outroot)
		warn 'in-source build' if @outroot == @srcroot
		@src_relative = srcroot.match?(/^\.\.[\\\/]/) && Rmk.normalize_path(srcroot)
		::Dir.mkdir @outroot unless ::Dir.exist? @outroot
		Dir.chdir @outroot
		Dir.mkdir '.rmk' unless Dir.exist? '.rmk'
		@mid_storage = Rmk::Storage.new '.rmk/mid', {}
		@dep_storage = Rmk::Storage.new '.rmk/dep', {}
		@srcfiles = {}
		@outfiles = {}
		@defaultfiles = []
		@vars = {'srcroot'=>@srcroot, 'outroot'=>@outroot, 'src_rto_root'=>@src_relative || @srcroot}
		@virtual_root = Rmk::VDir.new self, nil
	end
	attr_reader :srcroot, :outroot, :src_relative, :vars, :virtual_root, :srcfiles, :outfiles
	attr_reader :mid_storage, :dep_storage

	# join src file path relative to out root, or absolute src path when not relative src
	def join_rto_src_path(path) ::File.join @src_relative ? @src_relative : @srcroot, path end

	# split path pattern to dir part and file match regex part
	# @param pattern [String] absolute path, can include '*' to match any char at last no dir part
	# @return [Array(String, <Regex, nil>)] when pattern include '*', return [dir part, file match regex]
	# ;otherwise return [origin pattern, nil]
	def split_path_pattern(pattern)
		match = /^([a-zA-Z]:\/(?:[^\/*]+\/)*)([^\/*]*)(?:\*([^\/*]*))?$/.match pattern
		raise "file syntax '#{pattern}' error" unless match
		dir, prefix, postfix = *match[1..3]
		regex = postfix && /#{Regexp.escape prefix}(.*)#{Regexp.escape postfix}$/
		[regex ? dir : pattern, regex]
	end

	# find files which can be build's imput file
	# @param pattern [String] absolute path to find src and out files which can include '*' to match any char at last no dir part
	# @return [Array(Array<Hash>, <Regex,nil>)] return [files, regex], or [files, nil] when not include '*' pattern
	def find_inputfiles(pattern)
		pattern = Rmk.normalize_path pattern
		path, regex = split_path_pattern pattern
		if regex
			files = []
			@files_mutex.synchronize do
				@outfiles.each {|k, v| files << v if k.start_with?(path) && k[path.size..-1].match?(regex)}
				::Dir[pattern].each do |fn|
					next if @outfiles.include? fn
					next files << @srcfiles[fn] if @srcfiles.include? fn
					files << (@srcfiles[fn] = VFile.new rmk:self, path:fn, is_src:true)
				end
			end
			return files, regex
		else
			file = @files_mutex.synchronize do
				next @outfiles[path] if @outfiles.include? path
				next @srcfiles[path] if @srcfiles.include? path
				raise "file '#{path}' not exist" unless ::File.exist? path
				@srcfiles[path] = VFile.new rmk:self, path:path, is_src:true
			end
			return [file], nil
		end
	end

	# find files which must be build's output
	# @param pattern [String] absolute path to find out files which can include '*' to match any char at last no dir part
	# @return [Array<Hash>] return Array of file, and Regex when has '*' pattern
	def find_outfiles(pattern)
		pattern = Rmk.normalize_path pattern
		path, regex = split_path_pattern pattern
		files = []
		@files_mutex.synchronize do
			next @outfiles.include?(path) ? [@outfiles[path]] : files unless regex
			@outfiles.each {|k, v| files << v if k.start_with?(path) && k[path.size..-1].match?(regex)}
		end
		files
	end

	# register a out file
	# @param path [String]
	# @param vname [String]
	# @param vpath [String]
	# @return [Rmk::VFile] return file obj added
	def add_out_file(path:, vname:nil, vpath:nil)
		@files_mutex.synchronize do
			raise "file '#{path}' has been defined" if @outfiles.include? path
			file = @srcfiles.delete(path).change_to_out! file if @srcfiles.include? path
			@outfiles[path] = VFile.new rmk:self, path:path, vname:vname, vpath:vpath
		end
	end

	# register a src file
	# @param path [String]
	# @param vname [String]
	# @param vpath [String]
	# @return [Rmk::VFile] return file obj added
	def add_src_file(path:, vname:nil, vpath:nil)
		@files_mutex.synchronize do
			@outfiles[path] ||
				(@srcfiles[path] ||= VFile.new(rmk:self, path:path, vname:vname, vpath:vpath, is_src:true))
		end
	end

	# add default target
	def add_default(*files) @files_mutex.synchronize{@defaultfiles.concat files} end

	# parse project
	# @return [self]
	def parse
		@virtual_root.parse
		@dep_storage.wait_ready
		@dep_storage.data!.each do |path, fns|
			next warn "Rmk: warn: outfile '#{path}' not found when restore depfile" unless @outfiles.include? path
			build = @outfiles[path].output_ref_build
			fns.each do |fn|
				files, _ = @virtual_root.find_inputfiles fn
				files.each{|file| file.input_ref_builds << build; build.infiles << file}
			end
		end
		self
	end

	def build(*tgts)
		@mid_storage.wait_ready
		if tgts.empty?
			files = @defaultfiles
		else
			files = tgts.map do |name|
				file = Rmk.normalize_path name
				file = @outfiles[File.join @outroot, file] || @srcfiles[File.join @srcroot, file]
				raise "build target '#{name}' not found" unless file
				file = file.input_ref_builds[0].outfiles[0] if file.src? && file.input_ref_builds.size == 1
				file
			end
		end
		puts 'Rmk: build start'
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
		# @files_mid.each_key {|key| @files_mid.delete key unless @srcfiles.include? key}
		@mid_storage.save
		@dep_storage.data!.each_key {|key| @dep_storage.data!.delete key unless @outfiles.include? key}
		@dep_storage.save
	end

	class Rule < Vars; end
	class VFile; end
end
