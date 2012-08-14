#
# Copyright (c) 2012 Sean Laurent
#
class Module
  def dsl_accessor(*symbols)
    symbols.each { |sym|
      class_eval %{
        def #{sym}(*val)
          if val.empty?
            @#{sym}
          else
            @#{sym} = val.size == 1 ? val[0] : val
            self
          end
        end
      }
    }
  end
  
  def dsl_array_accessor(*symbols)
    symbols.each { |sym|
      class_eval %{
        def #{sym}(*val)
          if val.empty?
            @#{sym}
          else
            @#{sym} = [] if @#{sym}.nil?
            if val[0].kind_of? Array
              @#{sym} += val[0]
            else
              @#{sym} << val[0]
            end
            self
          end
        end
      }
    }
  end

  def dsl_regex_accessor(*symbols)
    symbols.each { |sym|
      class_eval %{
        def #{sym}(*val)
          if val.empty?
            @#{sym}
          else
            if val[0].kind_of? String
              @#{sym} = Regexp.new(val[0])
            else
              @#{sym} = val[0]
            end
            self
          end
        end
      }
    }
  end
end
