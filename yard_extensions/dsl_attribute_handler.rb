#
# Copyright (c) 2012 Sean Laurent
#

# Handles YARD documentation for the custom DSL methods
class DSLAttributeHandler < YARD::Handlers::Ruby::AttributeHandler
  handles_method_call(:dsl_accessor)
  handles_method_call(:dsl_array_accessor)
  namespace_only

  def process
    push_state(:scope => :class) { super }
  end
end