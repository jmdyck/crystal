require "./repl"
require "./instructions"

class Crystal::Repl::Compiler < Crystal::Visitor
  record CompilingBlock, block : Block, target_def : Def

  private getter scope : Type
  private getter def : Def?

  property compiled_block : CompiledBlock?
  getter instructions
  getter nodes
  property block_level = 0

  def initialize(
    @context : Context,
    @local_vars : LocalVars,
    @instructions : Array(Instruction) = [] of Instruction,
    @nodes : Hash(Int32, ASTNode) = {} of Int32 => ASTNode,
    scope : Type? = nil,
    @def = nil,
    @top_level = true
  )
    @scope = scope || @context.program

    # Do we want to push a value to the stack?
    # This value is false for nodes whose value is not needed.
    # For example, consider this code:
    #
    # ```
    # a = 1
    # 2
    # a
    # ```
    #
    # The value of the second node, `2`, is not needed at all
    # and so it's not even pushed to the stack.
    #
    # And, actually, the value of `a = 1` is not needed either
    # (it's not assigned to anything else after `a`).
    #
    # An alternative way to have done this is to push every
    # node to the stack, and pop afterwards if not needed
    # (this is in intermediary nodes of `Expressions`) but
    # this is less efficient.
    @wants_value = true

    # Do we want to produce a struct pointer instead of a struct
    # value?
    #
    # This is needed because a struct call receiver is actually
    # passed as a pointer, which becomes `self`. Then through
    # this pointer struct mutation is possible.
    #
    # For code like:
    #
    # ```
    # @foo.bar
    # ```
    #
    # this is handled by checking whether the receiver is an InstanceVar,
    # and if so, we load a pointer to the instance var.
    #
    # But what if it's something like this:
    #
    # ```
    # (cond ? @foo : @bar).bar
    # ```
    #
    # Assuming `@foo` and `@bar` have the same type, and `bar` mutates
    # them, we'd like to pass a pointer to them here too.
    # In this case we set `@wants_struct_pointer` to true, and then
    # when an instance variable is visited, we put the pointer instead
    # of the value. In this particular case we actually put some zeros
    # (the size of the struct) before the pointer because we don't know
    # whether other branches of the `if` (or expressions, in general)
    # will actually put a full struct followed by a pointer. For example:
    #
    # ```
    # (cond ? @foo : some_call).bar
    # ```
    #
    # In this case `some_call` returns a struct, and we'll push it to the
    # stack, and then we'll push a pointer to it. After `bar` is done
    # we remove the extra struct before the pointer. So in the case of
    # `@foo`, it must also produce something that's like `struct - pointer`
    # so that the struct is popped uniformly.
    @wants_struct_pointer = false
  end

  def self.new(
    context : Context,
    compiled_def : CompiledDef,
    top_level : Bool
  )
    new(
      context: context,
      local_vars: compiled_def.local_vars,
      instructions: compiled_def.instructions,
      nodes: compiled_def.nodes,
      scope: compiled_def.def.owner,
      def: compiled_def.def,
      top_level: top_level,
    )
  end

  def compile(node : ASTNode) : Nil
    node.accept self

    leave aligned_sizeof_type(node), node: nil
  end

  def compile_block(node : Block, target_def : Def) : Nil
    @compiling_block = CompilingBlock.new(node, target_def)
    node.args.reverse_each do |arg|
      block_var = node.vars.not_nil![arg.name]

      index = @local_vars.name_to_index(block_var.name, @block_level)
      # Don't use location so we don't pry break on a block arg (useless)
      set_local index, aligned_sizeof_type(block_var), node: nil
    end

    node.body.accept self
    upcast node.body, node.body.type, node.type

    leave aligned_sizeof_type(node), node: nil
  end

  def compile_def(node : Def) : Nil
    node.body.accept self

    final_type = node.type

    compiled_block = @compiled_block
    if compiled_block
      final_type = merge_block_break_type(final_type, compiled_block.block)
    end

    if node.type.nil_type?
      pop aligned_sizeof_type(node.body), node: nil
    else
      upcast node.body, node.body.type, final_type
    end

    leave aligned_sizeof_type(final_type), node: nil

    @instructions
  end

  private def inside_method?
    return false if @top_level

    !!@def
  end

  def visit(node : Nop)
    return false unless @wants_value

    put_nil node: node
    false
  end

  def visit(node : NilLiteral)
    return false unless @wants_value

    put_nil node: node
    false
  end

  def visit(node : BoolLiteral)
    return false unless @wants_value

    if node.value
      put_true node: node
    else
      put_false node: node
    end

    false
  end

  def visit(node : NumberLiteral)
    return false unless @wants_value

    compile_number(node, node.kind, node.value)

    false
  end

  private def compile_number(node, kind, value)
    case kind
    when :i8
      put_i8 value.to_i8, node: node
    when :u8
      put_u8 value.to_u8, node: node
    when :i16
      put_i16 value.to_i16, node: node
    when :u16
      put_u16 value.to_u16, node: node
    when :i32
      put_i32 value.to_i32, node: node
    when :u32
      put_u32 value.to_u32, node: node
    when :i64
      put_i64 value.to_i64, node: node
    when :u64
      put_u64 value.to_u64, node: node
    when :f32
      put_i32 value.to_f32.unsafe_as(Int32), node: node
    when :f64
      put_i64 value.to_f64.unsafe_as(Int64), node: node
    else
      node.raise "BUG: missing interpret for NumberLiteral with kind #{kind}"
    end
  end

  def visit(node : CharLiteral)
    return false unless @wants_value

    put_i32 node.value.ord, node: node
    false
  end

  def visit(node : StringLiteral)
    return false unless @wants_value

    # TODO: use a string pool?
    put_i64 node.value.object_id.unsafe_as(Int64), node: node
    false
  end

  def visit(node : SymbolLiteral)
    return false unless @wants_value

    index = @context.symbol_index(node.value)

    put_i32 index, node: node
    false
  end

  def visit(node : TupleLiteral)
    type = node.type.as(TupleInstanceType)

    current_offset = 0
    node.elements.each_with_index do |element, i|
      element.accept self
      aligned_size = aligned_sizeof_type(element)
      next_offset =
        if i == node.elements.size - 1
          aligned_sizeof_type(type)
        else
          @context.offset_of(type, i + 1)
        end

      difference = next_offset - (current_offset + aligned_size)
      if difference > 0
        push_zeros(difference, node: nil)
      elsif difference < 0
        pop(-difference, node: nil)
      end

      current_offset = next_offset
    end

    false
  end

  def visit(node : NamedTupleLiteral)
    type = node.type.as(NamedTupleInstanceType)

    current_offset = 0
    node.entries.each_with_index do |entry, i|
      entry.value.accept self
      aligned_size = aligned_sizeof_type(entry.value)
      next_offset =
        if i == node.entries.size - 1
          aligned_sizeof_type(type)
        else
          @context.offset_of(type, i + 1)
        end

      difference = next_offset - (current_offset + aligned_size)
      if difference > 0
        push_zeros(difference, node: nil)
      elsif difference < 0
        pop(-difference, node: nil)
      end

      current_offset = next_offset
    end

    false
  end

  def visit(node : ExceptionHandler)
    # TODO: rescues, else, etc.

    node.body.accept self

    if node_ensure = node.ensure
      discard_value node_ensure
    end

    false
  end

  def visit(node : Expressions)
    old_wants_value = @wants_value
    old_wants_struct_pointer = @wants_struct_pointer

    node.expressions.each_with_index do |expression, i|
      @wants_value = old_wants_value && i == node.expressions.size - 1
      @wants_struct_pointer = old_wants_struct_pointer && i == node.expressions.size - 1
      expression.accept self
    end

    @wants_value = old_wants_value
    @wants_struct_pointer = old_wants_struct_pointer

    false
  end

  def visit(node : Assign)
    raise_if_wants_struct_pointer(node)

    target = node.target
    case target
    when Var
      request_value(node.value)
      dup(aligned_sizeof_type(node.value), node: nil) if @wants_value

      index, type = lookup_local_var_index_and_type(target.name)

      # Before assigning to the var we must potentially box inside a union
      upcast node.value, node.value.type, type
      set_local index, aligned_sizeof_type(type), node: node
    when InstanceVar
      if inside_method?
        request_value(node.value)
        dup(aligned_sizeof_type(node.value), node: nil) if @wants_value

        ivar_offset = ivar_offset(scope, target.name)
        ivar = scope.lookup_instance_var(target.name)
        ivar_size = inner_sizeof_type(ivar.type)

        upcast node.value, node.value.type, ivar.type

        set_self_ivar ivar_offset, ivar_size, node: node
      else
        node.type = @context.program.nil_type
        put_nil node: nil if @wants_value
      end
    when ClassVar
      if inside_method?
        index, compiled_def = class_var_index_and_compiled_def(target)

        if compiled_def
          initialize_class_var_if_needed(target.var, index, compiled_def)
        end

        request_value(node.value)
        dup(aligned_sizeof_type(node.value), node: nil) if @wants_value

        var = target.var

        upcast node.value, node.value.type, var.type

        set_class_var index, aligned_sizeof_type(var), node: node
      else
        # TODO: eagerly initialize the class var?
        node.type = @context.program.nil_type
        put_nil node: nil if @wants_value
      end
    when Underscore
      node.value.accept self
    when Path
      const = target.target_const.not_nil!
      if const.value.simple_literal?
        const.value.accept self
      elsif const.fake_def
        index, compiled_def = get_const_index_and_compiled_def const

        # This will initialize the constant
        const_initialized index, node: nil
        pop(sizeof(Pointer(Void)), node: nil) # pop the bool value

        call compiled_def, node: nil
        dup(aligned_sizeof_type(const.value.type), node: nil) if @wants_value
        set_const index, aligned_sizeof_type(const.value), node: nil
      elsif @wants_value
        node.raise "BUG: missing interprter assign constant that isn't 'used'"
      end
    else
      node.raise "BUG: missing interpret for #{node.class} with target #{node.target.class}"
    end
    false
  end

  def visit(node : Var)
    return false unless @wants_value

    index, type = lookup_local_var_index_and_type(node.name)

    if node.name == "self" && type.passed_by_value?
      if @wants_struct_pointer
        push_zeros aligned_sizeof_type(scope), node: nil
        put_self(node: node)
        return false
      else
        # Load the entire self from the pointer that's self
        get_self_ivar 0, aligned_sizeof_type(type), node: node
      end
    else
      if @wants_struct_pointer
        push_zeros aligned_sizeof_type(node), node: nil
        pointerof_var index, node: node
      else
        get_local index, aligned_sizeof_type(type), node: node
      end
    end

    downcast node, type, node.type

    false
  end

  def lookup_local_var_index_and_type(name : String) : {Int32, Type}
    block_level = @block_level
    while block_level >= 0
      index = @local_vars.name_to_index?(name, block_level)
      if index
        type = @local_vars.type(name, block_level)
        return {index, type}
      end

      block_level -= 1
    end

    raise "BUG: can't find local var #{name}"
  end

  def visit(node : InstanceVar)
    return false unless @wants_value

    if @wants_struct_pointer
      push_zeros aligned_sizeof_type(node), node: nil
      compile_pointerof_ivar(node, node.name)
    else
      ivar_offset = ivar_offset(scope, node.name)
      ivar_size = inner_sizeof_type(scope.lookup_instance_var(node.name))

      get_self_ivar ivar_offset, ivar_size, node: node
    end

    false
  end

  def visit(node : ClassVar)
    return false unless @wants_value

    index, compiled_def = class_var_index_and_compiled_def(node)

    if compiled_def
      initialize_class_var_if_needed(node.var, index, compiled_def)
    end

    if @wants_struct_pointer
      push_zeros aligned_sizeof_type(node), node: nil
      pointerof_class_var(index, node: node)
    else
      get_class_var index, aligned_sizeof_type(node.var), node: node
    end

    false
  end

  private def class_var_index_and_compiled_def(node : ClassVar) : {Int32, CompiledDef?}
    var = node.var

    case var.owner
    when VirtualType
      node.raise "BUG: missing interpret class var for virtual type"
    when VirtualMetaclassType
      node.raise "BUG: missing interpret class var for virtual metaclass type"
    end

    index = @context.class_var_index?(var.owner, var.name)
    if index
      return index, @context.class_var_compiled_def(index)
    end

    initializer = var.initializer
    if initializer
      def_name = "#{var.owner}::#{var.name}}"
      fake_def = Def.new(def_name)
      fake_def.owner = var.owner

      compiled_def = CompiledDef.new(@context, fake_def, 0)

      # Declare local variables for the constant initializer
      initializer.meta_vars.each do |name, var|
        var_type = var.type?
        next unless var_type

        compiled_def.local_vars.declare(name, var_type)
      end

      value = initializer.node
      value = @context.program.cleanup(value)

      compiler = Compiler.new(@context, compiled_def, top_level: true)
      compiler.compile(value)

      if @context.decompile_defs
        puts "=== #{def_name} ==="
        puts Disassembler.disassemble(@context, compiled_def)
        puts "=== #{def_name} ==="
      end
    end

    index = @context.declare_class_var(var.owner, var.name, var.type, compiled_def)

    {index, compiled_def}
  end

  def visit(node : ReadInstanceVar)
    raise_if_wants_struct_pointer(node)

    # TODO: check struct
    node.obj.accept self

    type = node.obj.type

    ivar_offset = ivar_offset(type, node.name)
    ivar_size = inner_sizeof_type(type.lookup_instance_var(node.name))

    get_class_ivar ivar_offset, ivar_size, node: node
    false
  end

  def visit(node : UninitializedVar)
    raise_if_wants_struct_pointer(node)

    case var = node.var
    when Var
      var.accept self
    when InstanceVar
      # Nothing to do
    when ClassVar
      # TODO: declare the class var (though it will be declared later on)
    else
      node.raise "BUG: missing interpret UninitializedVar for #{var.class}"
    end

    false
  end

  def visit(node : If)
    if node.truthy?
      discard_value(node.cond)
      node.then.accept self
      return false unless @wants_value

      upcast node.then, node.then.type, node.type
      return false
    elsif node.falsey?
      discard_value(node.cond)
      node.else.accept self
      return false unless @wants_value

      upcast node.else, node.else.type, node.type
      return false
    end

    dont_request_struct_pointer do
      request_value(node.cond)
    end

    value_to_bool(node.cond, node.cond.type)

    branch_unless 0, node: nil
    cond_jump_location = patch_location

    node.then.accept self
    upcast node.then, node.then.type, node.type if @wants_value

    jump 0, node: nil
    then_jump_location = patch_location

    patch_jump(cond_jump_location)

    node.else.accept self
    upcast node.else, node.else.type, node.type if @wants_value

    patch_jump(then_jump_location)

    false
  end

  def visit(node : While)
    raise_if_wants_struct_pointer(node)

    # Jump directly to the condition
    jump 0, node: nil
    cond_jump_location = patch_location

    body_index = @instructions.size

    old_while = @while
    old_while_breaks = @while_breaks
    old_while_nexts = @while_nexts

    @while = node
    while_breaks = @while_breaks = [] of Int32
    while_nexts = @while_nexts = [] of Int32

    # Now write the body
    discard_value(node.body)

    # Here starts the condition.
    # Any `next` that happened leads us here.
    while_nexts.each do |while_next|
      patch_jump(while_next)
    end

    patch_jump(cond_jump_location)
    request_value(node.cond)
    value_to_bool(node.cond, node.cond.type)

    # If the condition holds, jump back to the body
    branch_if body_index, node: nil

    # Here we are at the point where the condition didn't hold anymore.
    # We must convert `nil` to whatever while's type is.
    upcast node.body, @context.program.nil_type, node.type

    # Otherwise we are at the end of the while.
    # Any `break` that happened leads us here
    while_breaks.each do |while_break|
      patch_jump(while_break)
    end

    unless @wants_value
      pop aligned_sizeof_type(node), node: nil
    end

    @while = old_while
    @while_breaks = old_while_breaks
    @while_nexts = old_while_nexts

    false
  end

  def visit(node : Return)
    raise_if_wants_struct_pointer(node)

    exp = node.exp

    exp_type =
      if exp
        request_value(exp)
        exp.type
      else
        put_nil node: node
        @context.program.nil_type
      end

    def_type = @def.not_nil!.type

    compiled_block = @compiled_block
    if compiled_block
      def_type = merge_block_break_type(def_type, compiled_block.block)
    end

    upcast node, exp_type, def_type

    if @compiling_block
      leave_def aligned_sizeof_type(def_type), node: node
    else
      leave aligned_sizeof_type(def_type), node: node
    end

    false
  end

  def visit(node : TypeOf)
    return false unless @wants_value

    put_type node.type, node: node
    false
  end

  def visit(node : SizeOf)
    return false unless @wants_value

    put_i32 inner_sizeof_type(node.exp), node: node

    false
  end

  def visit(node : Path)
    return false unless @wants_value

    if const = node.target_const
      if const.value.simple_literal?
        const.value.accept self
      else
        index = initialize_const_if_needed(const)
        if @wants_struct_pointer
          push_zeros(aligned_sizeof_type(const.value), node: nil)
          get_const_pointer index, node: node
        else
          get_const index, aligned_sizeof_type(const.value), node: node
        end
      end
    elsif replacement = node.syntax_replacement
      replacement.accept self
    else
      put_type node.type, node: node
    end
    false
  end

  private def get_const_index_and_compiled_def(const : Const) : {Int32, CompiledDef}
    index = @context.const_index?(const)
    if index
      return index, @context.const_compiled_def(index)
    end

    # TODO: support magic constants like ARGV_UNSAFE
    fake_def = const.fake_def.not_nil!
    fake_def.owner = const.visitor.not_nil!.current_type

    compiled_def = CompiledDef.new(@context, fake_def, 0)

    # Declare local variables for the constant initializer
    fake_def.vars.try &.each do |name, var|
      var_type = var.type?
      next unless var_type

      compiled_def.local_vars.declare(name, var_type)
    end

    value = const.value
    value = @context.program.cleanup(value)

    compiler = Compiler.new(@context, compiled_def, top_level: true)
    compiler.compile(value)

    if @context.decompile_defs
      puts "=== #{const} ==="
      puts Disassembler.disassemble(@context, compiled_def)
      puts "=== #{const} ==="
    end

    {@context.declare_const(const, compiled_def), compiled_def}
  end

  def visit(node : Generic)
    return false unless @wants_value

    put_type node.type, node: node
    false
  end

  def visit(node : PointerOf)
    return false unless @wants_value

    exp = node.exp
    case exp
    when Var
      index, type = lookup_local_var_index_and_type(exp.name)
      pointerof_var(index, node: node)
    when InstanceVar
      compile_pointerof_ivar(node, exp.name)
    when ClassVar
      compile_pointerof_class_var(node, exp)
    else
      node.raise "BUG: missing interpret for PointerOf with exp #{exp.class}"
    end
    false
  end

  private def compile_pointerof_ivar(node : ASTNode, name : String)
    index = scope.index_of_instance_var(name).not_nil!
    if scope.struct?
      pointerof_ivar(@context.offset_of(scope, index), node: node)
    else
      pointerof_ivar(@context.instance_offset_of(scope, index), node: node)
    end
  end

  private def compile_pointerof_class_var(node : ASTNode, exp : ClassVar)
    index, compiled_def = class_var_index_and_compiled_def(exp)

    if compiled_def
      initialize_class_var_if_needed(exp.var, index, compiled_def)
    end

    pointerof_class_var(index, node: node)
  end

  def visit(node : Not)
    exp = node.exp
    exp.accept self
    return false unless @wants_value

    value_to_bool(exp, exp.type)
    logical_not node: node

    false
  end

  def visit(node : Cast)
    raise_if_wants_struct_pointer(node)

    node.obj.accept self

    obj_type = node.obj.type
    to_type = node.to.type.virtual_type

    # TODO: check the proper conditions in codegen
    if obj_type == to_type
      # TODO: not tested
      nop
    elsif obj_type.pointer? && to_type.pointer?
      # Cast between pointers is nop
      nop
    elsif obj_type.pointer? && to_type.reference_like?
      # Cast from pointer to reference is nop
      nop
    elsif obj_type.reference_like? && to_type.is_a?(PointerInstanceType)
      # Cast from reference to pointer is nop
      nop
    elsif node.upcast?
      upcast node, obj_type, to_type
    else
      # Check if obj is a `to_type`
      dup aligned_sizeof_type(node.obj), node: nil
      is_a(node, obj_type, to_type)

      # If so, branch
      branch_if 0, node: nil
      cond_jump_location = patch_location

      # Otherwise we need to raise
      # TODO: actually raise
      unreachable "BUG: missing handling of `.as(...)` when it fails", node: nil

      patch_jump(cond_jump_location)
      downcast node.obj, obj_type, to_type
    end

    false
  end

  def visit(node : NilableCast)
    # TODO: not tested
    node.obj.accept self

    obj_type = node.obj.type
    to_type = node.to.type.virtual_type

    # TODO: check the proper conditions in codegen
    if obj_type == to_type
      nop
    else
      # Check if obj is a `to_type`
      dup aligned_sizeof_type(node.obj), node: nil
      is_a(node, obj_type, to_type)

      # If so, branch
      branch_if 0, node: nil
      cond_jump_location = patch_location

      # Otherwise it's nil
      put_nil node: nil
      pop aligned_sizeof_type(node.obj), node: nil
      upcast node.obj, @context.program.nil_type, node.type
      jump 0, node: nil
      otherwise_jump_location = patch_location

      patch_jump(cond_jump_location)
      downcast node.obj, obj_type, to_type
      upcast node.obj, to_type, node.type

      patch_jump(otherwise_jump_location)
    end

    false
  end

  def visit(node : IsA)
    node.obj.accept self
    return false unless @wants_value

    obj_type = node.obj.type
    const_type = node.const.type

    is_a(node, obj_type, const_type)

    false
  end

  private def is_a(node, type, target_type)
    type = type.remove_indirection
    filtered_type = type.filter_by(target_type).not_nil!

    if type == filtered_type
      # TODO: not tested
      pop aligned_sizeof_type(type), node: nil
      put_true node: nil
      return
    end

    case type
    when VirtualType
      reference_is_a(type_id(filtered_type), node: node)
    when MixedUnionType
      union_is_a(aligned_sizeof_type(type), type_id(filtered_type), node: node)
    when NilableType
      if filtered_type.nil_type?
        pointer_is_null(node: node)
      else
        pointer_is_not_null(node: node)
      end
    when NilableReferenceUnionType
      if filtered_type.nil_type?
        # TODO: not tested
        pointer_is_null(node: node)
      else
        # TODO: maybe missing checking against another reference union type?
        reference_is_a(type_id(filtered_type), node: node)
      end
    when ReferenceUnionType
      case filtered_type
      when NonGenericClassType
        reference_is_a(type_id(filtered_type), node: node)
      when GenericClassInstanceType
        # TODO: not tested
        reference_is_a(type_id(filtered_type), node: node)
      when VirtualType
        # TODO: not tested
        reference_is_a(type_id(filtered_type), node: node)
      else
        node.raise "BUG: missing IsA from #{type} to #{target_type} (#{type.class} to #{target_type.class})"
      end
    else
      node.raise "BUG: missing IsA from #{type} to #{target_type} (#{type.class} to #{target_type.class})"
    end
  end

  def visit(node : Call)
    obj = node.obj

    target_defs = node.target_defs
    unless target_defs
      node.raise "BUG: no target defs"
    end

    if target_defs.size == 1
      target_def = target_defs.first
    else
      target_def = Multidispatch.create_def(@context, node, target_defs)
    end

    body = target_def.body
    if body.is_a?(Primitive)
      visit_primitive(node, body)
      return false
    end

    if obj && (obj_type = obj.type).is_a?(LibType)
      compile_lib_call(node, obj_type)
      return false
    end

    compiled_def = @context.defs[target_def]? ||
                   create_compiled_def(node, target_def)

    pop_obj = dont_request_struct_pointer do
      compile_call_args(node, target_def)
    end

    if (block = node.block) && !block.fun_literal
      call_with_block compiled_def, node: node
    else
      call compiled_def, node: node
    end

    if @wants_value
      # Pop the struct that's on the stack, if any, if obj was a struct
      # (but the struct is after the call's value, so we must
      # remove it past that value)
      pop_from_offset aligned_sizeof_type(pop_obj), aligned_sizeof_type(node), node: nil if pop_obj
      put_stack_top_pointer_if_needed(node)
    else
      if pop_obj
        pop aligned_sizeof_type(node) + aligned_sizeof_type(pop_obj), node: nil
      else
        pop aligned_sizeof_type(node), node: nil
      end
    end

    false
  end

  private def compile_lib_call(node : Call, obj_type)
    target_def = node.target_def
    external = target_def.as(External)

    args_bytesizes = [] of Int32
    args_ffi_types = [] of FFI::Type
    proc_args = [] of FFI::CallInterface?

    dont_request_struct_pointer do
      node.args.each do |arg|
        arg_type = arg.type

        if arg.is_a?(NilLiteral)
          # Nil is used to mean Pointer.null
          put_i64 0, node: arg
        else
          request_value(arg)
        end
        # TODO: upcast?

        if arg_type.is_a?(ProcInstanceType)
          args_bytesizes << aligned_sizeof_type(arg)
          args_ffi_types << FFI::Type.pointer
          proc_args << arg_type.ffi_call_interface
        else
          case arg
          when NilLiteral
            args_bytesizes << sizeof(Pointer(Void))
            args_ffi_types << FFI::Type.pointer
          when Out
            # TODO: this out handling is bad. Why is out's type not a pointer already?
            args_bytesizes << sizeof(Pointer(Void))
            args_ffi_types << FFI::Type.pointer
          else
            args_bytesizes << aligned_sizeof_type(arg)
            args_ffi_types << arg.type.ffi_type
          end
          proc_args << nil
        end
      end
    end

    if node.named_args
      node.raise "BUG: missing lib call with named args"
    end

    if external.varargs?
      lib_function = LibFunction.new(
        def: external,
        symbol: @context.c_function(obj_type, external.real_name),
        call_interface: FFI::CallInterface.variadic(
          abi: FFI::ABI::DEFAULT,
          args: args_ffi_types,
          return_type: external.type.ffi_type,
          fixed_args: external.args.size,
          total_args: node.args.size,
        ),
        args_bytesizes: args_bytesizes,
        proc_args: proc_args,
      )
      @context.add_gc_reference(lib_function)
    else
      lib_function = @context.lib_functions[external] ||= LibFunction.new(
        def: external,
        symbol: @context.c_function(obj_type, external.real_name),
        call_interface: FFI::CallInterface.new(
          abi: FFI::ABI::DEFAULT,
          args: args_ffi_types,
          return_type: external.type.ffi_type,
        ),
        args_bytesizes: args_bytesizes,
        proc_args: proc_args,
      )
    end

    lib_call(lib_function, node: node)

    if @wants_value
      put_stack_top_pointer_if_needed(node)
    else
      pop aligned_sizeof_type(node), node: nil
    end

    return false
  end

  private def create_compiled_def(node : Call, target_def : Def)
    block = node.block
    block = nil if block && !block.visited? && !block.fun_literal

    # Compile the block too if there's one
    if block && !block.fun_literal
      compiled_block = create_compiled_block(block, target_def)
    end

    args_bytesize = 0

    obj = node.obj
    args = node.args
    named_args = node.named_args
    obj_type = obj.try(&.type) || target_def.owner

    if obj_type == @context.program
      # Nothing
    elsif obj_type.passed_by_value?
      args_bytesize += sizeof(Pointer(UInt8))
    else
      args_bytesize += aligned_sizeof_type(obj_type)
    end

    i = 0

    # This is the case of a multidispatch with an explicit "self" being passed
    i += 1 if target_def.args.first?.try &.name == "self"

    args.each do
      target_def_arg = target_def.args[i]
      target_def_var_type = target_def.vars.not_nil![target_def_arg.name].type
      args_bytesize += aligned_sizeof_type(target_def_var_type)

      i += 1
    end

    named_args.try &.each do
      target_def_arg = target_def.args[i]
      target_def_var_type = target_def.vars.not_nil![target_def_arg.name].type
      args_bytesize += aligned_sizeof_type(target_def_var_type)

      i += 1
    end

    # If the block is captured there's an extra argument
    if block && block.fun_literal
      args_bytesize += sizeof(Proc(Void))
    end

    compiled_def = CompiledDef.new(@context, target_def, args_bytesize)

    # We don't cache defs that yield because we inline the block's contents
    if block
      @context.add_gc_reference(compiled_def)
    else
      @context.defs[target_def] = compiled_def
    end

    # Declare local variables for the newly compiled function
    target_def.vars.try &.each do |name, var|
      var_type = var.type?
      next unless var_type

      compiled_def.local_vars.declare(name, var_type)
    end

    compiler = Compiler.new(@context, compiled_def, top_level: false)
    compiler.compiled_block = compiled_block

    begin
      compiler.compile_def(target_def)
    rescue ex : Crystal::CodeError
      node.raise "compiling #{node}", inner: ex
    end

    if @context.decompile_defs
      puts "=== #{target_def.owner}##{target_def.name} ==="
      puts compiled_def.local_vars
      puts Disassembler.disassemble(@context, compiled_def)
      puts "=== #{target_def.owner}##{target_def.name} ==="
    end

    compiled_def
  end

  private def create_compiled_block(block : Block, target_def : Def)
    bytesize_before_block_local_vars = @local_vars.current_bytesize

    @local_vars.push_block

    begin
      block.vars.try &.each do |name, var|
        var_type = var.type?
        next unless var_type

        next if var.context != block

        @local_vars.declare(name, var_type)
      end

      bytesize_after_block_local_vars = @local_vars.current_bytesize

      block_args_bytesize = block.args.sum { |arg| aligned_sizeof_type(arg) }

      compiled_block = CompiledBlock.new(block, @local_vars,
        args_bytesize: block_args_bytesize,
        locals_bytesize_start: bytesize_before_block_local_vars,
        locals_bytesize_end: bytesize_after_block_local_vars,
      )

      # Store it so the GC doesn't collect it (it's in the instructions but it might not be aligned)
      @context.add_gc_reference(compiled_block)

      compiler = Compiler.new(@context, @local_vars,
        instructions: compiled_block.instructions,
        nodes: compiled_block.nodes,
        scope: @scope, def: @def, top_level: false)
      compiler.compiled_block = @compiled_block
      compiler.block_level = block_level + 1
      compiler.compile_block(block, target_def)

      if @context.decompile_defs
        puts "=== #{target_def.owner}##{target_def.name}#block ==="
        puts Disassembler.disassemble(@context, compiled_block.instructions, compiled_block.nodes, @local_vars)
        puts "=== #{target_def.owner}##{target_def.name}#block ==="
      end
    ensure
      @local_vars.pop_block
    end

    compiled_block
  end

  private def compile_call_args(node : Call, target_def : Def)
    # Self for structs is passed by reference
    pop_obj = nil

    obj = node.obj
    if obj
      if obj.type.passed_by_value?
        pop_obj = compile_struct_call_receiver(obj, target_def.owner)
      else
        request_value(obj)
      end
    else
      # Pass implicit self if needed
      put_self(node: node) unless node.scope.is_a?(Program)
    end

    target_def_args = target_def.args

    i = 0

    # This is the case of a multidispatch with an explicit "self" being passed
    i += 1 if target_def.args.first?.try &.name == "self"

    node.args.each do |arg|
      arg_type = arg.type
      target_def_arg = target_def_args[i]
      target_def_var_type = target_def.vars.not_nil![target_def_arg.name].type

      compile_call_arg(arg, arg_type, target_def_var_type)

      i += 1
    end

    node.named_args.try &.each do |n|
      arg = n.value
      arg_type = arg.type
      target_def_arg = target_def_args[i]
      target_def_var_type = target_def.vars.not_nil![target_def_arg.name].type

      compile_call_arg(arg, arg_type, target_def_var_type)

      i += 1
    end

    if fun_literal = node.block.try(&.fun_literal)
      request_value fun_literal
    end

    pop_obj
  end

  private def compile_call_arg(arg, arg_type, target_def_var_type)
    # Check autocasting from symbol to enum
    if arg.is_a?(SymbolLiteral) && target_def_var_type.is_a?(EnumType)
      symbol_name = arg.value.underscore
      target_def_var_type.types.each do |enum_name, enum_value|
        if enum_name.underscore == symbol_name
          request_value(enum_value.as(Const).value)
          return
        end
      end
    end

    if arg_type != target_def_var_type && arg.is_a?(NumberLiteral)
      case target_def_var_type
      when IntegerType
        # Autocast to integer
        compile_number(arg, target_def_var_type.kind, arg.value)
        return
      when FloatType
        # Autocast to float
        compile_number(arg, target_def_var_type.kind, arg.value)
        return
      end
    end

    request_value(arg)

    # We need to cast the argument to the target_def variable
    # corresponding to the argument. If for example we have this:
    #
    # ```
    # def foo(x : Int32)
    #   x = nil
    # end
    #
    # foo(1)
    # ```
    #
    # Then the actual type of `x` inside `foo` is (Int32 | Nil),
    # and we must cast `1` to it.
    upcast arg, arg_type, target_def_var_type
  end

  private def compile_struct_call_receiver(obj : ASTNode, owner : Type)
    case obj
    when Var
      if obj.name == "self"
        self_type = @def.not_nil!.vars.not_nil!["self"].type
        if self_type == owner
          put_self(node: obj)
        else
          # It might happen that self's type was narrowed down,
          # so we need to accept it regularly and downcast it.
          # TODO: how to handle needs_struct_pointer?
          request_value(obj)

          # Then take a pointer to it (this is self inside the method)
          put_stack_top_pointer(aligned_sizeof_type(obj), node: nil)

          # We must remember to later pop the struct that's still on the stack
          pop_obj = obj
        end
      else
        ptr_index, var_type = lookup_local_var_index_and_type(obj.name)
        if obj.type == var_type
          pointerof_var(ptr_index, node: obj)
        elsif var_type.is_a?(MixedUnionType) && obj.type.struct?
          # Get pointer of var
          pointerof_var(ptr_index, node: obj)

          # Add 8 to it, to reach the union value
          put_i64 8_i64, node: nil
          pointer_add 1_i64, node: nil
        elsif var_type.is_a?(MixedUnionType) && obj.type.is_a?(MixedUnionType)
          pointerof_var(ptr_index, node: obj)
        else
          obj.raise "BUG: missing call receiver by value cast from #{var_type} to #{obj.type} (#{var_type.class} to #{obj.type.class})"
        end
      end
    when InstanceVar
      compile_pointerof_ivar(obj, obj.name)
    when ClassVar
      compile_pointerof_class_var(obj, obj)
    when Path
      const = obj.target_const.not_nil!
      index = initialize_const_if_needed(const)
      get_const_pointer index, node: obj
    else
      if needs_struct_pointer?(obj.type)
        request_struct_pointer(obj)
      else
        # For a struct, we first put it on the stack
        request_value(obj)

        # Then take a pointer to it (this is self inside the method)
        put_stack_top_pointer(aligned_sizeof_type(obj), node: nil)
      end

      # We must remember to later pop the struct that's still on the stack
      pop_obj = obj
    end

    pop_obj
  end

  private def initialize_const_if_needed(const)
    index, compiled_def = get_const_index_and_compiled_def const

    # Do this:
    #
    # ```
    # unless const_initialized(index)
    #   call const_initializer
    #   set_const index
    # end
    # ```

    # This is `unless const_initialized(index)`
    const_initialized index, node: nil
    branch_if 0, node: nil
    cond_jump_location = patch_location

    # Now we are on the `then` branch
    call compiled_def, node: nil
    set_const index, aligned_sizeof_type(const.value), node: nil

    # Here we are outside of the unless
    patch_jump(cond_jump_location)

    index
  end

  private def initialize_class_var_if_needed(var, index, compiled_def)
    # Do this:
    #
    # ```
    # unless class_var_initialized(index)
    #   call class_var_initializer
    #   set_class_var index
    # end
    # ```

    # This is `unless class_var_initialized(index)`
    class_var_initialized index, node: nil
    branch_if 0, node: nil
    cond_jump_location = patch_location

    # Now we are on the `then` branch
    call compiled_def, node: nil
    set_class_var index, aligned_sizeof_type(var), node: nil

    # Here we are outside of the unless
    patch_jump(cond_jump_location)

    index
  end

  private def accept_call_members(node : Call)
    dont_request_struct_pointer do
      if obj = node.obj
        obj.accept(self)
      else
        put_self(node: node) unless scope.is_a?(Program)
      end

      node.args.each &.accept(self)
      node.named_args.try &.each &.value.accept(self)
    end
  end

  def visit(node : Out)
    case exp = node.exp
    when Var
      index, type = lookup_local_var_index_and_type(exp.name)
      pointerof_var(index, node: node)
    when InstanceVar
      compile_pointerof_ivar(node, exp.name)
    when Underscore
      node.raise "BUG: missing interpret out with underscore"
      # Nothing to do
    else
      node.raise "BUG: unexpected out exp: #{exp}"
    end

    false
  end

  def visit(node : ProcLiteral)
    is_closure = node.def.closure?
    if is_closure
      node.raise "BUG: closures not yet supported"
    end

    # TODO: This was copied from Codegen. Why is it not in CleanupTransformer?
    # If we don't care about a proc literal's return type then we mark the associated
    # def as returning void. This can't be done in the type inference phase because
    # of bindings and type propagation.
    if node.force_nil?
      node.def.set_type @context.program.nil
    else
      # Use proc literal's type, which might have a broader type then the body
      # (for example, return type: Int32 | String, body: String)
      node.def.set_type node.return_type
    end

    target_def = node.def
    target_def.owner = @context.program
    args = target_def.args

    # 1. Compile def
    args_bytesize = args.sum { |arg| aligned_sizeof_type(arg) }
    compiled_def = CompiledDef.new(@context, target_def, args_bytesize)

    # 2. Store it in context
    @context.add_gc_reference(compiled_def)

    # Declare local variables for the newly compiled function
    target_def.vars.try &.each do |name, var|
      var_type = var.type?
      next unless var_type

      # TODO: closures!
      next if var.context != target_def

      compiled_def.local_vars.declare(name, var_type)
    end

    compiler = Compiler.new(@context, compiled_def, top_level: false)
    begin
      compiler.compile_def(target_def)
    rescue ex : Crystal::CodeError
      node.raise "compiling #{node}", inner: ex
    end

    if @context.decompile_defs
      puts "=== ProcLiteral ==="
      puts Disassembler.disassemble(@context, compiled_def)
      puts "=== ProcLiteral ==="
    end

    # 3. Push compiled_def id to stack
    put_i64 compiled_def.object_id.to_i64!, node: node

    # 4. Push context to stack (null for now, so i64 0)
    put_i64 0, node: node

    false
  end

  def visit(node : Break)
    raise_if_wants_struct_pointer(node)

    exp = node.exp

    exp_type =
      if exp
        request_value(exp)
        exp.type
      else
        put_nil node: node

        @context.program.nil_type
      end

    if target_while = @while
      target_while = @while.not_nil!

      upcast node, exp_type, target_while.type

      jump 0, node: nil
      @while_breaks.not_nil! << patch_location
    elsif compiling_block = @compiling_block
      block = compiling_block.block
      target_def = compiling_block.target_def

      final_type = merge_block_break_type(target_def.type, block)

      upcast node, exp_type, final_type

      break_block aligned_sizeof_type(final_type), node: node
    else
      node.raise "BUG: break without target while or block"
    end

    false
  end

  def visit(node : Next)
    raise_if_wants_struct_pointer(node)

    exp = node.exp

    if @while
      if exp
        discard_value(exp)
      else
        put_nil node: node
      end

      jump 0, node: nil
      @while_nexts.not_nil! << patch_location
    elsif compiling_block = @compiling_block
      exp_type =
        if exp
          request_value(exp)
          exp.type
        else
          put_nil node: node
          @context.program.nil_type
        end

      upcast node, exp_type, compiling_block.block.type
      leave aligned_sizeof_type(compiling_block.block.type), node: node
    else
      node.raise "BUG: next without target while or block"
    end

    false
  end

  def visit(node : Yield)
    compiled_block = @compiled_block.not_nil!
    block = compiled_block.block

    splat_index = block.splat_index
    if splat_index
      node.raise "BUG: block with splat not yet supported"
    end

    if node.exps.any?(Splat)
      node.raise "BUG: splat inside yield not yet supported"
    end

    pop_obj = nil

    # Check if tuple unpacking is needed
    if node.exps.size == 1 &&
       (tuple_type = node.exps.first.type).is_a?(TupleInstanceType) &&
       block.args.size > 1
      # Accept the tuple
      exp = node.exps.first
      dont_request_struct_pointer do
        request_value exp
      end

      # We need to cast to the block var, not arg
      # (the var might have more types in it if it's assigned other values)
      block_var_types = block.args.map do |arg|
        block.vars.not_nil![arg.name].type
      end

      unpack_tuple exp, tuple_type, block_var_types

      # We need to discard the tuple value that comes before the unpacked values
      pop_obj = tuple_type
    else
      node.exps.each_with_index do |exp, i|
        if i < block.args.size
          dont_request_struct_pointer do
            request_value(exp)
          end

          # We need to cast to the block var, not arg
          # (the var might have more types in it if it's assigned other values)
          block_arg = block.args[i]
          block_var = block.vars.not_nil![block_arg.name]

          upcast exp, exp.type, block_var.type
        else
          discard_value(exp)
        end
      end
    end

    call_block compiled_block, node: node

    if @wants_value
      pop_from_offset aligned_sizeof_type(pop_obj), aligned_sizeof_type(node), node: nil if pop_obj
      put_stack_top_pointer_if_needed(node)
    else
      if pop_obj
        pop aligned_sizeof_type(node) + aligned_sizeof_type(pop_obj), node: nil
      else
        pop aligned_sizeof_type(node), node: nil
      end
    end

    false
  end

  def visit(node : ClassDef)
    # TODO: change scope
    discard_value node.body

    return false unless @wants_value

    put_nil(node: node)
    false
  end

  def visit(node : ModuleDef)
    # TODO: change scope
    discard_value node.body

    return false unless @wants_value

    put_nil(node: node)
    false
  end

  def visit(node : EnumDef)
    # TODO: visit body?
    false
  end

  def visit(node : Def)
    false
  end

  def visit(node : FunDef)
    false
  end

  def visit(node : LibDef)
    false
  end

  def visit(node : Macro)
    false
  end

  def visit(node : VisibilityModifier)
    node.exp.accept self
    false
  end

  def visit(node : Annotation)
    false
  end

  def visit(node : AnnotationDef)
    false
  end

  def visit(node : TypeDeclaration)
    false
  end

  def visit(node : Alias)
    false
  end

  def visit(node : Include)
    false
  end

  def visit(node : Extend)
    false
  end

  def visit(node : Unreachable)
    unreachable("Reached the unreachable", node: node)

    false
  end

  def visit(node : FileNode)
    file_module = @context.program.file_module(node.filename)

    a_def = Def.new(node.filename)
    a_def.body = node.node
    a_def.owner = @context.program
    a_def.type = @context.program.nil_type

    compiled_def = CompiledDef.new(@context, a_def, 0)

    file_module.vars.each do |name, var|
      var_type = var.type?
      next unless var_type

      compiled_def.local_vars.declare(name, var_type)
    end

    compiler = Compiler.new(@context, compiled_def, top_level: true)
    compiler.compile_def(a_def)

    @context.add_gc_reference(compiled_def)

    if @context.decompile_defs
      puts "=== #{node.filename} ==="
      puts Disassembler.disassemble(@context, compiled_def)
      puts "=== #{node.filename} ==="
    end

    call compiled_def, node: node
  end

  def visit(node : ASTNode)
    node.raise "BUG: missing interpret for #{node.class}"
  end

  {% for name, instruction in Crystal::Repl::Instructions %}
    {% operands = instruction[:operands] %}

    def {{name.id}}(
      {% if operands.empty? %}
        *, node : ASTNode?
      {% else %}
        {{*operands}}, *, node : ASTNode?
      {% end %}
    ) : Nil
      @nodes[@instructions.size] = node if node

      append OpCode::{{ name.id.upcase }}
      {% for operand in operands %}
        append {{operand.var}}
      {% end %}
    end
  {% end %}

  private def request_value(node : ASTNode)
    accept_with_wants_value node, true
  end

  private def discard_value(node : ASTNode)
    dont_request_struct_pointer do
      accept_with_wants_value node, false
    end
  end

  private def accept_with_wants_value(node : ASTNode, wants_value)
    old_wants_value = @wants_value
    @wants_value = wants_value
    node.accept self
    @wants_value = old_wants_value
  end

  private def request_struct_pointer(node : ASTNode)
    old_wants_stuct_pointer = @wants_struct_pointer
    @wants_struct_pointer = true
    request_value node
    @wants_struct_pointer = old_wants_stuct_pointer
  end

  private def dont_request_struct_pointer
    old_wants_stuct_pointer = @wants_struct_pointer
    @wants_struct_pointer = false
    value = yield
    @wants_struct_pointer = old_wants_stuct_pointer
    value
  end

  private def put_stack_top_pointer_if_needed(value)
    if @wants_struct_pointer
      put_stack_top_pointer(aligned_sizeof_type(value), node: nil)
    end
  end

  private def raise_if_wants_struct_pointer(node : ASTNode)
    # We'll slowly handle these cases, but they are probably very uncommon.
    # We still want to know where they happen!
    if @wants_struct_pointer
      node.raise "BUG: missing handling of @wants_struct_pointer for #{node.class}"
    end
  end

  # TODO: block.break shouldn't exist: the type should be merged in target_def
  private def merge_block_break_type(def_type : Type, block : Block)
    block_break_type = block.break.type?
    if block_break_type
      @context.program.type_merge([def_type, block_break_type] of Type) ||
        @context.program.no_return
    else
      def_type
    end
  end

  private def put_true(*, node : ASTNode?)
    put_i64 1_i64, node: node
  end

  private def put_false(*, node : ASTNode?)
    put_i64 0_i64, node: node
  end

  private def put_i8(value : Int8, *, node : ASTNode)
    put_i64 value.to_i64!, node: node
  end

  private def put_u8(value : UInt8, *, node : ASTNode)
    put_i64 value.to_u64!.to_i64!, node: node
  end

  private def put_i16(value : Int16, *, node : ASTNode)
    put_i64 value.to_i64!, node: node
  end

  private def put_u16(value : UInt16, *, node : ASTNode)
    put_i64 value.to_u64!.to_i64!, node: node
  end

  private def put_i32(value : Int32, *, node : ASTNode)
    put_i64 value.to_i64!, node: node
  end

  private def put_u32(value : UInt32, *, node : ASTNode)
    put_i64 value.to_u64!.to_i64!, node: node
  end

  private def put_u64(value : UInt64, *, node : ASTNode)
    put_i64 value.to_i64!, node: node
  end

  private def put_type(type : Type, *, node : ASTNode)
    put_i32 type_id(type), node: node
  end

  private def put_def(a_def : Def)
  end

  private def put_self(*, node : ASTNode)
    if scope.struct?
      if scope.passed_by_value?
        get_local 0, sizeof(Pointer(UInt8)), node: node
      else
        get_local 0, aligned_sizeof_type(scope), node: node
      end
    else
      get_local 0, sizeof(Pointer(UInt8)), node: node
    end
  end

  private def append(op_code : OpCode)
    append op_code.value
  end

  private def append(a_def : CompiledDef)
    append(a_def.object_id.unsafe_as(Int64))
  end

  private def append(a_block : CompiledBlock)
    append(a_block.object_id.unsafe_as(Int64))
  end

  private def append(lib_function : LibFunction)
    append(lib_function.object_id.unsafe_as(Int64))
  end

  private def append(call : Call)
    append(call.object_id.unsafe_as(Int64))
  end

  private def append(string : String)
    append(string.object_id.unsafe_as(Int64))
  end

  private def append(value : Int64)
    value.unsafe_as(StaticArray(UInt8, 8)).each do |byte|
      append byte
    end
  end

  private def append(value : Int32)
    value.unsafe_as(StaticArray(UInt8, 4)).each do |byte|
      append byte
    end
  end

  private def append(value : Int16)
    value.unsafe_as(StaticArray(UInt8, 2)).each do |byte|
      append byte
    end
  end

  private def append(value : Int8)
    append value.unsafe_as(UInt8)
  end

  private def append(value : Symbol)
    value.unsafe_as(StaticArray(UInt8, 4)).each do |byte|
      append byte
    end
  end

  private def append(value : UInt8)
    @instructions << value
  end

  private def patch_location
    @instructions.size - 4
  end

  private def patch_jump(offset : Int32)
    (@instructions.to_unsafe + offset).as(Int32*).value = @instructions.size
  end

  private def aligned_sizeof_type(node : ASTNode) : Int32
    @context.aligned_sizeof_type(node)
  end

  private def aligned_sizeof_type(type : Type) : Int32
    @context.aligned_sizeof_type(type)
  end

  private def inner_sizeof_type(node : ASTNode) : Int32
    @context.inner_sizeof_type(node)
  end

  private def inner_sizeof_type(type : Type) : Int32
    @context.inner_sizeof_type(type)
  end

  private def aligned_instance_sizeof_type(type : Type) : Int32
    @context.aligned_instance_sizeof_type(type)
  end

  private def ivar_offset(type : Type, name : String) : Int32
    @context.ivar_offset(type, name)
  end

  private def type_id(type : Type)
    @context.type_id(type)
  end

  # The only types that we want to put a struct pointer for
  # (for @wants_struct_pointer) are mutable types that are not
  # inside a union. The reason is that if they are inside a union,
  # they are already copied, so passing a perfect pointer is useless.
  private def needs_struct_pointer?(type : Type)
    case type
    when PrimitiveType, PointerInstanceType, ProcInstanceType,
         TupleInstanceType, NamedTupleInstanceType, MixedUnionType
      false
    when StaticArrayInstanceType
      true
    when VirtualType
      type.struct?
    when NonGenericModuleType
      type.including_types.try { |t| needs_struct_pointer?(t) }
    when GenericModuleInstanceType
      type.including_types.try { |t| needs_struct_pointer?(t) }
    when GenericClassInstanceType
      needs_struct_pointer?(type.generic_type)
    when TypeDefType
      needs_struct_pointer?(type.typedef)
    when AliasType
      needs_struct_pointer?(type.aliased_type)
    when ClassType
      type.struct?
    else
      false
    end
  end

  private macro nop
  end
end
