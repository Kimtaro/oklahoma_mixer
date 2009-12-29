require "oklahoma_mixer/hash_database/c"
require "oklahoma_mixer/array_list"
require "oklahoma_mixer/extensible_string"

module OklahomaMixer
  class HashDatabase
    ###########################
    ### Opening and Closing ###
    ###########################
    
    def initialize(path, options = { })
      @path        = path
      @db          = C.new
      self.default = options[:default]
      C.open(@db, path, (1 << 1) | (1 << 2))
    end
    
    def close
      C.del(@db)  # closes before it deletes the object
    end
    
    ################################
    ### Getting and Setting Keys ###
    ################################
    
    def default(key = nil)
      @default[key] if @default
    end
    
    def default=(value_or_proc)
      @default = case value_or_proc
                 when Proc then value_or_proc
                 when nil  then nil
                 else           lambda { |key| value_or_proc }
                 end
    end
    
    def store(key, value, mode = nil)
      k, v   = key.to_s, value.to_s
      result = value
      if block_given?
        warn "block supersedes mode argument" unless mode.nil?
        callback = lambda { |old_value_pointer, old_size, returned_size, _|
          old_value   = old_value_pointer.get_bytes(0, old_size)
          replacement = yield(key, old_value, value).to_s
          returned_size.put_int(0, replacement.size)
          FFI::MemoryPointer.from_string(replacement)
        }
        C.putproc(@db, k, k.size, v, v.size, callback, nil)
      else
        case mode
        when :keep
          result = C.putkeep(@db, k, k.size, v, v.size)
        when :cat
          C.putcat(@db, k, k.size, v, v.size)
        when :async
          C.putasync(@db, k, k.size, v, v.size)
        when :counter
          result = case value
                   when Float then C.adddouble(@db, k, k.size, value)
                   else            C.addint(@db, k, k.size, value.to_i)
                   end
        else
          C.put(@db, k, k.size, v, v.size)
        end
      end
      result
    end
    alias_method :[]=, :store
    
    def fetch(key, *default)
      k        = key.to_s
      if value = C.read_from_func(:get, @db, k, k.size)
        value
      else
        if block_given?
          warn "block supersedes default value argument" unless default.empty?
          yield key
        elsif not default.empty?
          default.first
        else
          fail IndexError, "key not found"
        end
      end
    end
    
    def [](key)
      fetch(key, &@default)
    rescue IndexError
      nil
    end
    
    def update(hash, &dup_handler)
      hash.each do |key, value|
        store(key, value, &dup_handler)
      end
      self
    end
    
    def values_at(*keys)
      keys.map { |key| self[key] }
    end
    
    def keys(options = { })
      prefix = options.fetch(:prefix, "").to_s
      limit  = options.fetch(:limit,  -1)
      list   = ArrayList.new(C.fwmkeys(@db, prefix, prefix.size, limit))
      list.to_a
    ensure
      list.free if list
    end
    
    def values
      values = [ ]
      each_value do |value|
        values << value
      end
      values
    end
    
    def delete(key, &missing_handler)
      value = fetch(key, &missing_handler)
      k     = key.to_s
      C.out(@db, k, k.size)
      value
    rescue IndexError
      nil
    end
    
    def clear
      C.vanish(@db)
      self
    end
    
    def include?(key)
      fetch(key)
      true
    rescue IndexError
      false
    end
    alias_method :has_key?, :include?
    alias_method :key?,     :include?
    alias_method :member?,  :include?
    
    def size
      C.rnum(@db)
    end
    alias_method :length, :size
    
    #################
    ### Iteration ###
    #################
    
    include Enumerable
    
    def each_key
      C.iterinit(@db)
      loop do
        return self unless key = C.read_from_func(:iternext, @db)
        yield key
      end
    end
    
    def each
      C.iterinit(@db)
      loop do
        Utilities.temp_xstr do |key|
          Utilities.temp_xstr do |value|
            return self unless C.iternext3(@db, key.pointer, value.pointer)
            yield [key.to_s, value.to_s]
          end
        end
      end
    end
    alias_method :each_pair, :each
    
    def each_value
      each do |key, value|
        yield value
      end
    end
    
    def delete_if
      each do |key, value|
        delete(key) if yield key, value
      end
    end
  end
end
