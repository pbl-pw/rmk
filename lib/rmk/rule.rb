require_relative 'rmk'

class Rmk::Rule
	Var = Struct.new :append?, :value

	# create Rule
	# @param command [String] exec command template
	def initialize(command)
		@command = command
		@vars = {}
	end
	attr_reader :command

	def vars; self end

	def [](name) @vars[name]&.value end

	# add var define template
	# @return Array<Var>
	def []=(name, append = false, value) @vars[name] = Var.new(append, value) end

	def apply_to(tgt)
		@vars.each{|name, var| var.append? ? tgt[name] += var.value : tgt[name] = var.value }
	end
end
