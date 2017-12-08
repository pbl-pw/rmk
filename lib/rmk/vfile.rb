require_relative 'rmk'

# virtual file which represent a real OS file
class Rmk::VFile
	attr_reader :path, :vname, :vpath
	attr_accessor :is_src

	def src?; @is_src end

	# builds which include this file as input file
	def input_ref_builds; @ibuilds end

	# builds which include this file as order-only file
	def order_ref_builds; @odbuilds end

	# builds which include this file as output file
	def output_ref_builds; @obuilds end

	def initialize(path:, vname:nil, vpath:nil, is_src:false)
		raise 'virtual file must set vpath' if vname && !vpath
		@path, @vname, @vpath, @is_src = path, vname, vpath, is_src
		@ibuilds = []
		@obuilds, @odbuilds = [], [] unless is_src
	end

	def updated!; input_ref_builds.each{|build| build.input_updated!} end
end
