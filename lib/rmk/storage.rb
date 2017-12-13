require_relative 'schedule'

class Rmk::Storage
	# create
	# @param file [String] file path
	# @param iniobj [Object] init inside obj
	def initialize(file, iniobj)
		@mutex = Thread::Mutex.new
		@file = file
		@data = File.exist?(@file) ? Rmk::Schedule.new_thread!{Marshal.load IO.binread @file} : iniobj
	end

	# wait for storage ready to read and write
	# @note before call this method storage is not ready, can't call any follow methods
	def wait_ready; @mutex.synchronize{@data = @data.value if Thread === @data} end

	# save data to disk file
	def save; @mutex.synchronize{IO.binwrite @file, Marshal.dump(@data)} end

	# run block in mutex sync protected
	# @yieldparam data [Hash] inside Hash obj
	# @return [Object] block's result
	def sync(&cmd) @mutex.synchronize{cmd.call @data} end

	# get inside Hash obj without sync protected
	def data!; @data end

	# redirect undef method to inside data obj with sync protected, often used for single operation
	def method_missing(name, *parms, &cmd) @mutex.synchronize{@data.send name, *parms, &cmd} end
end
