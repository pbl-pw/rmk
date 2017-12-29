require_relative 'rmk'

class Rmk::Rule
	Var = Struct.new :append?, :value

	# create Rule
	# @param command [String] exec command template
	def initialize(command)
		@command = command
		@vars = {}
		@rmk_vars = {'out'=>nil, 'collection'=>nil}
	end
	attr_reader :command

	def vars; self end

	def [](name) @rmk_vars[name] end

	# add var define template
	# @return Array<Var>
	def []=(name, append = false, value)
		return @vars[name] = Var.new(append, value) unless @rmk_vars.include? name
		raise "special var '#{name}' can't be append" if append
		@rmk_vars[name] = value
	end

	def apply_to(tgt)
		@vars.each{|name, var| var.append? ? tgt[name] += var.value : tgt[name] = var.value }
	end
end
