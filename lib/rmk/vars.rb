class Rmk; end

class Rmk::Vars < Hash
	# create vars
	# @param rmk [Hash] rmk system reserved vars, query first so will not be override
	# @param upstream [Rmk::Vars, nil] upstream vars for lookup var which current obj not include
	def initialize(rmk, upstream) @rmk, @upstream = rmk, upstream end
	attr_reader :rmk, :upstream

	# create new downstream vars which will lookup first, when not found then lookup current obj
	# @param clone_rmk [Boolean] dup a new rmk Hash or not, usually dup when need add reserved vars
	def downstream_new(clone_rmk:false) Rmk::Vars.new clone_rmk ? @rmk.clone(freeze:false) : @rmk, self end

	protected def fetch(name) super(name, nil) || @upstream&.fetch(name) end

	def [](name) @rmk[name] ||  fetch(name) end

	def []=(name, append = false, value)
		value = interpolate_str value.to_s
		super name, append ? self[name].to_s + value : value
	end

	protected def member?(name) super(name) || @upstream&.member?(name) end

	def include?(name, inherit = true) inherit ? @rmk.include?(name) || member?(name) : super(name) end

	alias_method :org_keys, :keys

	protected def get_keys; @upstream ? org_keys + @upstream.get_keys : org_keys end

	def keys(inherit = true) inherit ? @rmk.keys + get_keys : super() end

	# only do #{\w+} interpolate
	def preprocess_str(str) str.gsub(/\$((?:\$\$)*){(\w+)}/){"#{$1}#{self[$2]}"} end

	# do all '$' prefix escape str interpolate
	def unescape_str(str) str.gsub(/\$(?:([\$\s>&])|(\w+))/){$1 || self[$2]} end

	# preprocess str, and then unescape the result
	def interpolate_str(str) unescape_str preprocess_str str end

	# preprocess str,and then split use white spaces, and then unescape each result, typically used for split file list
	# @param str [String] str to split
	# @return [Array<String>]
	def split_str(str)
		str = preprocess_str str
		result = []
		until str.empty?
			head, _, str = str.partition /(?<!\$)(?:\$\$)*\K\s+/
			result << unescape_str(head) unless head.empty?
		end
		result
	end
end

class Rmk::MultiVarWriter
	# create
	# @param vars [Array<Rmk::Vars>] init Vars obj array
	def initialize(*vars) @vars = vars end

	# add vars obj to array
	# @param vars [Rmk::Vars] vars obj
	def <<(vars) @vars << vars end

	# write var to all vars obj
	# @param name [String]
	# @param append [Boolean] is '+=' mode ?
	# @param value [String, nil]
	def []=(name, append = false, value) @vars.each{|var| var[name, append] = value} end
end
