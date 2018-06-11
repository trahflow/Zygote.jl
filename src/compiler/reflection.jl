using Core: CodeInfo

struct Meta
  method::Method
  code::CodeInfo
  static_params
end

function untyped_meta(T, world = ccall(:jl_get_world_counter, UInt, ()))
  F = T.parameters[1]
  (F.name.module === Core.Compiler || F <: Core.Builtin || F <: Core.Builtin) && return nothing
  _methods = Base._methods_by_ftype(T, -1, world)
  length(_methods) == 1 || return nothing
  type_signature, sps, method = first(_methods)
  linfo = Core.Compiler.code_for_method(method, T, sps, world)
  ci = Core.Compiler.retrieve_code_info(linfo)
  return Meta(method, ci, sps)
end

function typed_meta(T; world = ccall(:jl_get_world_counter, UInt, ()), optimize = false)
  F = T.parameters[1]
  (F.name.module === Core.Compiler || F <: Core.Builtin || F <: Core.Builtin) && return nothing
  _methods = Base._methods_by_ftype(T, -1, world)
  length(_methods) == 1 || return nothing
  type_signature, sps, method = first(_methods)
  params = Core.Compiler.Params(world)
  (_, ci, ty) = Core.Compiler.typeinf_code(method, type_signature, sps, optimize, true, params)
  return Meta(method, ci, sps)
end

function IRCode(meta::Meta)
  Core.Compiler.just_construct_ssa(meta.code, deepcopy(meta.code.code), Int(meta.method.nargs)-1)
end

function spliceargs!(meta::Meta, ir::IRCode, args...)
  for i = 1:length(ir.stmts)
    ir[SSAValue(i)] = argmap(x -> Argument(x.n+length(args)), ir[SSAValue(i)])
  end
  for (name, T) in reverse(args)
    pushfirst!(ir.argtypes, T)
    pushfirst!(meta.code.slottypes, T)
    pushfirst!(meta.code.slotnames, name)
  end
  return ir
end

# Behave as if the function signature is f(args...)
# TODO varargs functions
function varargs!(meta::Meta, ir::IRCode)
  Ts = ir.argtypes[2:end]
  meta.code.slotnames = [:f, :args]
  meta.code.slottypes = Any[meta.code.slottypes[1], Tuple{Ts...}]
  empty!(ir.argtypes); append!(ir.argtypes, meta.code.slottypes)
  ir = IncrementalCompact(ir)
  map = Dict{Argument,SSAValue}()
  for i = 1:length(Ts)
    map[Argument(i+1)] = insert_node_here!(ir, xcall(Base, :getfield, Argument(2), i), Ts[i], 0)
  end
  for (i, x) in ir
    ir[i] = argmap(a -> get(map, a, a), x)
  end
  return finish(ir)
end

function update!(meta::Meta, ir::IRCode)
  Core.Compiler.replace_code_newstyle!(meta.code, ir, length(ir.argtypes)-1)
end

@generated function roundtrip(f, args...)
  meta = typed_meta(Tuple{f,args...})
  ir = IRCode(meta)
  ir = varargs!(meta, ir)
  ir = spliceargs!(meta, ir, (:self, typeof(roundtrip)))
  update!(meta, ir)
  return meta.code
end