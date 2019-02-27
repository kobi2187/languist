template log(a: string) =
  if helpers.debug:
    styledWriteLine(stdout, fgBlue, a, resetStyle)

template emitNode(s: untyped): untyped =
  generator.generateNode(`s`)

template ensure(k: untyped): untyped =
  assert node.kind == `k`

let nilNode = nkNilLit.newTree()
let emptyNode = newNode(nkEmpty)

macro generateIdent(s: untyped): untyped =
  result = quote:
    let label = translateIdentifier(`s`, generator.identifierCollisions)
    var res = newIdentNode(PIdent(s: label), TLineInfo())
    if label == "$":
      res = nkAccQuoted.newTree(res)
    res


macro generateDirectIdent(s: untyped): untyped =
  result = quote:
    newIdentNode(PIdent(s: `s`), TLineInfo())

proc generateNode(generator: var Generator, node: Node): PNode

proc generateAssign(generator: var Generator, node: Node): PNode

proc generateType(generator: var Generator, typ: Type): PNode


proc generateImports(generator: var Generator, imp: seq[Node]): PNode =
  assert len(imp) == 0 or imp[0].kind == Import

  var labels: seq[PNode] = @[]
  var aliases: seq[Node] = @[]
  for child in imp:
    labels = labels.concat(child.children.mapIt(generateDirectIdent(it.label)))
    aliases = aliases.concat(child.aliases)
  let top = nkImportStmt.newTree(labels)
  if len(aliases) > 0:
    let aliasNodes = aliases.mapIt(generator.generateAssign(it))
    result = nkStmtList.newTree(top)
    for alias in aliasNodes:
      result.add(alias)
  else:
    result = top

proc generateMethod(generator: var Generator, met: Node): PNode

proc generateClass(generator: var Generator, t: Node): PNode =
  assert t.kind in {Class}

  assert t.typ.kind == T.Object

  var recList: PNode
  var docstring: PNode
  if len(t.typ.fields) > 0:
    recList = nkRecList.newTree()
    if len(t.docstring) > 0:
      recList.add(newNode(nkEmpty))
      recList[^1].comment = t.docstring.join("\n")
    for member, a in t.typ.fields:
      recList.add(nkIdentDefs.newTree(
        nkPostfix.newTree(generateIdent("*"), generateIdent(member)),
        generator.generateType(a),
        emptyNode))
  else:
    recList = emptyNode
    if len(t.docstring) > 0:
      docstring = newNode(nkEmpty)
      docstring.comment = t.docstring.join("\n")


  var base: PNode
  if not t.typ.base.isNil:
    base = nkOfInherit.newTree(generator.generateType(t.typ.base))
  elif t.typ.inherited:
    base = nkOfInherit.newTree(generateIdent("RootObj"))
  else:
    base = emptyNode
  var objectNode = nkObjectTy.newTree(
      emptyNode, base, recList)

  if t.typ.isRef:
    objectNode = nkRefTy.newTree(
      objectNode)
  var tNode = nkTypeDef.newTree(
    nkPostfix.newTree(generateIdent("*"), generateIdent(t.label)),
    emptyNode,
    objectNode)

  result = nkTypeSection.newTree(tNode)
  if not docstring.isNil:
    result.add(docstring)
  result = nkStmtList.newTree(result)
  for met in t.methods:
    result.add(generator.generateMethod(met.node))


proc generateType(generator: var Generator, typ: Type): PNode =
  if typ.isNil:
    result = generateIdent("void")
  else:
    case typ.kind:
    of T.Simple, T.Object:
      var typLabel = typ.label
      if typLabel == "type":
        typLabel = "typedesc"
      elif typLabel == "bytes":
        typLabel = "cstring"
      elif typLabel in @["Int", "Void", "Bool", "String"]:
        typLabel = typLabel.toLowerAscii()
      result = generateIdent(typLabel)
    of T.Tuple:
      result = nkPar.newTree()
      for element in typ.elements:
        result.add(generator.generateType(element))
    of T.Compound:
      result = nkBracketExpr.newTree(generateIdent(typ.original.label))
      for arg in typ.args:
        result.add(generator.generateType(arg))
    of T.Generic:
      result = nkBracketExpr.newTree(generateIdent(typ.label))
      for arg in typ.genericArgs:
        result.add(generateIdent(arg))
    of T.Macro:
      result = nkCall.newTree(generateIdent(typ.label))
      for arg in typ.macroArgs:
        result.add(generator.generateType(arg))
    else:
      result = generateIdent($typ.kind)
    if typ.isVar:
      result = nkVarTy.newTree(result)
    # elif typ.isRef:
      # result = nkRefTy.newTree(result)

proc generateArgs(generator: var Generator, nodes: seq[Node], typ: Type): PNode

proc generateForward(generator: var Generator, function: Node): PNode =
  assert function.kind in {NodeMethod, Block}

  echo function.typ.isNil
  let args = generator.generateArgs(function.args, function.typ)

  var name = generateIdent(function.label)
  name = nkPostfix.newTree(
      generateIdent("*"),
      name)
  if function.typ.kind == T.Method:
    var genericArgs: seq[string] = @[]
    for arg in function.typ.args:
      case arg.kind:
      of T.Generic:
        for label in arg.genericArgs:
          if label notin genericArgs:
            genericArgs.add(label)
      of T.GenericVar:
        if arg.label notin genericArgs:
          genericArgs.add(arg.label)
      else:
        discard

    if len(genericArgs) > 0:
      name = nkBracketExpr.newTree(name)
      for arg in genericArgs:
        name.add(generateIdent(arg))

  if not function.isIterator:
    if function.kind == Block:
      result = nkLambda.newTree()
    elif function.isMethod:
      result = nkMethodDef.newTree()
    else:
      result = nkProcDef.newTree()
  else:
    result = nkIteratorDef.newTree()
  if function.kind == NodeMethod:
    result.add(name)
  else:
    result.add(emptyNode)
  result.add(emptyNode)
  result.add(emptyNode)
  result.add(args)
  result.add(emptyNode)
  result.add(emptyNode)
  result.add(emptyNode)

proc generateArgs(generator: var Generator, nodes: seq[Node], typ: Type): PNode =
  var iTyp = typ
  if typ.kind == T.MethodOverload:
    iTyp = typ.overloads[0]
  result = nkFormalParams.newTree()
  result.add(generator.generateType(iTyp.returnType))
  var z = 0
  for arg in nodes:
    var argTyp = if z < len(iTyp.args): iTyp.args[z] else: VoidType
    result.add(nkIdentDefs.newTree(
      generateIdent(arg.label),
      generator.generateType(argTyp),
      emptyNode))
    z += 1

proc generateMethod(generator: var Generator, met: Node): PNode =
  assert met.kind in {NodeMethod, Block}

  result = generator.generateForward(met)

  var children = nkStmtList.newTree()
  for child in met.code:
    children.add(emitNode(child))
  result.sons[^1] = children
  if len(met.doc) > 0:
    var docstring = newNode(nkEmpty)
    docstring.comment = met.doc.join("\n")
    result.sons[^1] = nkStmtList.newTree(docstring, result.sons[^1])

# proc generateFunction(generator: var Generator, function: Node): PNode =
#   assert function.kind in {PyFunctionDef}

#   result = generator.generateForward(function)

#   var children = emitNode(function[2])
#   if children.kind != nkStmtList:
#     children = nkStmtList.newTree(children)
#   result.sons[^1] = children
#   if len(function.doc) > 0:
#     var docstring = newNode(nkEmpty)
#     docstring.comment = function.doc.join("\n")
#     result.sons[^1] = nkStmtList.newTree(docstring, result.sons[^1])

proc generateDeclaration(generator: var Generator, declaration: Declaration): string =
  let declarations: array[Declaration, string] = ["", "let ", "var ", "const "]
  result = declarations[declaration]

proc generateAssign(generator: var Generator, node: Node): PNode =
  ensure(Assign)

  let name = emitNode(node[0])
  let value = emitNode(node[1])
  case node.declaration:
  of Declaration.Var:
    result = nkVarSection.newTree(nkIdentDefs.newTree(name, emptyNode, value))
  of Declaration.Let:
    result = nkLetSection.newTree(nkIdentDefs.newTree(name, emptyNode, value))
  of Declaration.Const:
    result = nkConstSection.newTree(nkConstDef.newTree(name, emptyNode, value))
  of Declaration.Existing:
    result = nkAsgn.newTree(name, value)

proc generateNew(generator: var Generator, node: Node): PNode =
  let good = generateIdent("init" & node[0].label)
  result = nkCall.newTree(good)
  for arg in node.children[1 .. ^1]:
    result.add(emitNode(arg))

proc generateVariable(generator: var Generator, node: Node): PNode =
  result = generateIdent(node.label)

proc generateIf(generator: var Generator, node: Node): PNode =
  # ugh python uses if(test, body, orelse=if(test, body, orelse..))
  # and nim if(elif(test, body), elif(test, body)..)
  ensure(If)

  result = nkIfStmt.newTree()

  var last = node
  while not last.isNil and last.kind == If:
    var elifBranch = nkElifBranch.newTree(
      emitNode(last[0]),
      emitNode(last[1]))
    last = last[2]
    if not last.isNil and len(last.children) > 0:
      while not last.isNil and last.kind == Code and len(last.children) == 1:
        last = last[0]
      if last.kind != If:
        result.add(elifBranch)
        result.add(nkElse.newTree(emitNode(last)))
        break
    result.add(elifBranch)

proc generateWhen(generator: var Generator, node: Node): PNode =
  ensure(NimWhen)

  result = nkWhen.newTree(
    nkElifBranch.newTree(
      emitNode(node[0]),
      emitNode(node[1])))
  if not node[2].isNil and len(node[2].children) > 0:
    result[0].add(nkElse.newTree(emitNode(node[2])))

proc generateGroup(generator: var Generator, group: seq[Node]): PNode =
  assert group[0].kind == Assign
  result = case group[0].declaration:
    of Declaration.Var: nkVarSection.newTree()
    of Declaration.Let: nkLetSection.newTree()
    of Declaration.Const: nkConstSection.newTree()
    else: nkStmtList.newTree()
  for element in group:
    var e = element
    e.declaration = Declaration.Existing
    result.add(emitNode(e))

proc generateCode(generator: var Generator, node: Node): PNode =
  ensure(Code)

  result = nkStmtList.newTree()
  var z = 0
  while z < len(node.children):
    var child = node[z]
    var group: seq[Node] = @[]
    while z < len(node.children) - 1 and not node[z + 1].isNil and
          child.kind == Assign and node[z + 1].kind == Assign and
          child.declaration != Declaration.Existing and child.declaration == node[z + 1].declaration:
      group.add(node[z])
      z += 1
    if len(group) > 0:
      group.add(node[z])
      result.add(generator.generateGroup(group))
    else:
      result.add(emitNode(child))
    z += 1

proc generateSend(generator: var Generator, node: Node): PNode =
  result = nkCall.newTree(
    nkDotExpr.newTree(emitNode(node[0]), generateIdent(node[1].text)))
  for arg in node.children[2 .. ^1]:
    result.add(emitNode(arg))

proc generateCall(generator: var Generator, node: Node): PNode =
  result = nkCall.newTree(emitNode(node[0]))
  for i, arg in node.children:
    if i > 0:
      result.add(emitNode(arg))

  if node[0].kind == Variable and node[0].label == "echo":
    result.kind = nkCommand


proc generateCommand(generator: var Generator, node: Node): PNode =
  result = nkCommand.newTree(emitNode(node[0]))
  for i, arg in node.children:
    if i > 0:
      result.add(emitNode(arg))


proc generateReturn(generator: var Generator, node: Node): PNode =
  ensure(Return)

  result = nkReturnStmt.newTree(emitNode(node[0]))

proc generateInt(generator: var Generator, node: Node): PNode =
  result = nkIntLit.newNode()
  result.intVal = node.i

proc generateFloat(generator: var Generator, node: Node): PNode =
  ensure(Float)

  result = nkFloatLit.newNode()
  result.floatVal = node.f

proc generateAttribute(generator: var Generator, node: Node): PNode =
  ensure(Attribute)

  assert node[1].kind == String

  result = nkDotExpr.newTree(emitNode(node[0]), generateIdent(node[1].text))

proc generateStr(generator: var Generator, node: Node): PNode =
  result = nkStrLit.newNode()
  result.strVal = node.text

proc generateDocstring(generator: var Generator, node: Node): PNode =
  result = nkStrLit.newNode()
  result.strVal = node.text

let SYMBOLS* = {
  PyAdd: "+",
  PySub: "-",
  PyMult: "*",
  PyDiv: "/",
  PyFloorDiv: "//",
  PyPow: "**",
  PyEq: "==",
  PyNotEq: "!=",
  PyLtE: "<=",
  PyGtE: ">=",
  PyGt: ">",
  PyLt: "<",
  PyAnd: "and",
  PyOr: "or",
  PyNot: "not",
  PyUSub: "-",
  PyIs: "is",
  PyIsNot: "isnot",
  PyIn: "in",
  PyNotIn: "notin",
  PyBitAnd: "and",
  PyBitOr: "or",
  PyMod: "mod",
}.toTable()

proc generateOp(generator: var Generator, op: Node): PNode =
  # echo op
  let s = if SYMBOLS.hasKey(op.kind): SYMBOLS[op.kind] else: op.label
  result = generateIdent(s)

proc generateBinOp(generator: var Generator, node: Node): PNode =
  ensure(BinOp)

  result = nkInfix.newTree(
    generateIdent(node[0].label),
    emitNode(node[1]),
    emitNode(node[2]))

proc generateCompare(generator: var Generator, node: Node): PNode =
  ensure(PyCompare)

  result = nkInfix.newTree(
    generator.generateOp(node[0]),
    emitNode(node[1]),
    emitNode(node[2]))

proc generateConstr(generator: var Generator, node: Node): PNode =
  assert node[0].typ.kind == T.Object

  if node[0].typ.init == "":
    result = nkObjConstr.newTree(
      emitNode(node[0]))
    for z in 0..min(node[1].children.high, node[2].children.high):
      result.add(nkExprColonExpr.newTree(emitNode(node[1][z]), emitNode(node[2][z])))
  else:
    result = nkCall.newTree(
      generateIdent(node[0].typ.init))
    for child in node[2]:
      result.add(emitNode(child))

proc generateNameConstant(generator: var Generator, node: Node): PNode =
  let label = node[0].label
  case label:
  of "True", "False":
    result = generateIdent(label.toLowerAscii())
  else:
    result = nilNode

proc generateForIn(generator: var Generator, node: Node): PNode =
  if node[0].kind != PyTuple:
    result = nkForStmt.newTree()
    for child in node.children:
      result.add(emitNode(child))
  else:
    result = nkForStmt.newTree(
      emitNode(node[0][0]),
      emitNode(node[0][1]),
      emitNode(node[1]),
      emitNode(node[2]))

proc generateForRange(generator: var Generator, node: Node): PNode =
  var code = nkStmtList.newTree()
  for child in node[3].children:
    code.add(emitNode(child))
  let rangeCode = nkInfix.newTree(generateIdent("..<"), emitNode(node[1]), emitNode(node[2]))
  result = nkForStmt.newTree(
    emitNode(node[0]),
    rangeCode,
    code)

proc generateSequence(generator: var Generator, node: Node): PNode =
  result = nkPrefix.newTree(generateIdent("@"), nkBracket.newTree())
  for child in node:
    result[1].add(emitNode(child))

proc generateRangeLess(generator: var Generator, node: Node): PNode =
  result = nkInfix.newTree(generateIdent("..<"), emitNode(node[0]), emitNode(node[1]))

proc generateTable(generator: var Generator, node: Node): PNode =
  var dict = nkTableConstr.newTree()
  for z in 0..<len(node.children):
    dict.add(nkExprColonExpr.newTree(emitNode(node[z][0]), emitNode(node[z][1])))
  result = nkCall.newTree(nkDotExpr.newTree(dict, generateIdent("newTable")))

proc generateWhile(generator: var Generator, node: Node): PNode =
  result = nkWhileStmt.newTree(emitNode(node[0]), emitNode(node[1]))

proc generateUnaryOp(generator: var Generator, node: Node): PNode =
  result = nkPrefix.newTree(generateIdent(node[0].label), emitNode(node[1]))

proc generateExprColonExpr(generator: var Generator, node: Node): PNode =
  result = nkExprColonExpr.newtree(emitNode(node[0]), emitNode(node[1]))

proc generateTry(generator: var Generator, node: Node): PNode =
  result = nkTryStmt.newTree(emitNode(node[0]))
  for child in node[1]:
    result.add(emitNode(child))

proc generateIndex(generator: var Generator, node: Node): PNode =
  result = nkBracketExpr.newTree(emitNode(node[0]), emitNode(node[1]))

proc generateExceptHandler(generator: var Generator, node: Node): PNode =
  result = nkExceptBranch.newTree(
    if node[0].kind != PyNone: emitNode(node[0]) else: emptyNode,
    emitNode(node[1]))

proc generateRaise(generator: var Generator, node: Node): PNode =
  result = nkRaiseStmt.newTree(emitNode(node[0]))

proc generateInfix(generator: var Generator, node: Node): PNode =
  result = nkInfix.newTree(emitNode(node[0]), emitNode(node[1]), emitNode(node[2]))

proc generateAccQuoted(generator: var Generator, node: Node): PNode =
  result = nkAccQuoted.newTree(emitNode(node[0]))

proc generateYield(generator: var Generator, node: Node): PNode =
  result = nkYieldStmt.newTree(emitNode(node[0]))

proc generateBreak(generator: var Generator, node: Node): PNode =
  result = nkBreakStmt.newTree(emptyNode)

proc generateWith(generator: var Generator, node: Node): PNode =
  result = nkCommand.newTree(
    generateIdent("with"),
    emitNode(node[0][0]),
    emitNode(node[1]))

proc generateOf(generator: var Generator, node: Node): PNode =
  result = nkInfix.newTree(generateIdent("of"), emitNode(node[0]), emitNode(node[1]))

proc generateTuple(generator: var Generator, node: Node): PNode =
  result = nkPar.newTree()
  for child in node:
    result.add(emitNode(child))

proc generatePrefix(generator: var Generator, node: Node): PNode =
  result = nkPrefix.newTree(emitNode(node[0]), emitNode(node[1]))

proc generateImport(generator: var Generator, node: Node): PNode =
  result = nkImportStmt.newTree()
  for child in node:
    result.add(emitNode(child))

proc generateAugAssign(generator: var Generator, node: Node): PNode =
  result = nkInfix.newTree(generateIdent("+="), emitNode(node[0]), emitNode(node[1]))

proc generateMath(generator: var Generator, op: string, node: Node): PNode =
  result = nkInfix.newTree(generateIdent(op), emitNode(node[0]), emitNode(node[1]))

proc generateSlice(generator: var Generator, node: Node): PNode =
  var start = if node[0].kind != Nil: emitNode(node[0]) else: newIntNode(nkIntLit, 0)
  var finish = if node[0].kind != Nil: emitNode(node[1]) else: nkPrefix.newTree(generateIdent("^"), newIntNode(nkIntLit, 1))
  var op = if node[0].kind != Nil: "..<" else: ".."
  result = nkInfix.newTree(generateIdent(op), start, finish)

proc generateCommentedOut(generator: var Generator, node: Node): PNode =
  result = newNode(nkEmpty)
  if node[0].kind == String:
    result.comment = fmt"py2nim can't generate code for{endl}{node[0].text}"

proc generateContinue(generator: var Generator, node: Node): PNode =
  result = nkContinueStmt.newTree(emptyNode)

proc homogeneous(node: Node): bool =
  node.children.len == 0 or node.children.allIt(it.kind == node.children[0].kind)

proc generateNode(generator: var Generator, node: Node): PNode =
  # TODO: macro
  log fmt"generate {node.kind}"
  if node.isNil:
    result = nilNode
    return
  case node.kind:
  of Assign:
    result = generator.generateAssign(node)
  of New:
    result = generator.generateNew(node)
  of Variable:
    result = generator.generateVariable(node)
  of Self:
    result = generateIdent("self")
  of PyNone:
    result = nilNode
  of If:
    result = generator.generateIf(node)
  of NimWhen:
    result = generator.generateWhen(node)
  of Code:
    result = generator.generateCode(node)
  of Call:
    result = generator.generateCall(node)
  of Command:
    result = generator.generateCommand(node)
  of Return:
    result = generator.generateReturn(node)
  of Int:
    result = generator.generateInt(node)
  of Float:
    result = generator.generateFloat(node)
  of Attribute:
    result = generator.generateAttribute(node)
  of Send:
    result = generator.generateSend(node)
  of String, Symbol:
    result = generator.generateStr(node)
  of Docstring: 
    result = generator.generateDocstring(node)
  of BinOp:
    result = generator.generateBinOp(node)
  of PyCompare:
    result = generator.generateCompare(node)
  of PyConstr:
    result = generator.generateConstr(node)
  of PyNameConstant:
    result = generator.generateNameConstant(node)
  of ForIn:
    result = generator.generateForIn(node)
  of ForRange:
    result = generator.generateForRange(node)
  of Block:
    result = generator.generateMethod(node)
  of Sequence:
    if homogeneous(node):
      result = generator.generateSequence(node)
    else:
      result = generator.generateTuple(node)
  of NimRangeLess:
    result = generator.generateRangeLess(node)
  of Table:
    result = generator.generateTable(node)
  of While:
    result = generator.generateWhile(node)
  of UnaryOp:
    result = generator.generateUnaryOp(node)
  of NimExprColonExpr:
    result = generator.generateExprColonExpr(node)
  of NimTuple:
    result = generator.generateTuple(node)
  of PyTry:
    result = generator.generateTry(node)
  of Index:
    result = generator.generateIndex(node)
  of PyExceptHandler:
    result = generator.generateExceptHandler(node)
  of PyRaise:
    result = generator.generateRaise(node)
  of NimInfix:
    result = generator.generateInfix(node)
  of NimAccQuoted:
    result = generator.generateAccQuoted(node)
  of Yield:
    result = generator.generateYield(node)
  of Break:
    result = generator.generateBreak(node)
  of PyWith:
    result = generator.generateWith(node)
  of NimOf:
    result = generator.generateOf(node)
  of PyTuple:
    result = generator.generateTuple(node)
  of NimPrefix:
    result = generator.generatePrefix(node)
  of Import:
    result = generator.generateImport(node)
#  of PyIndex:
 #   result = generator.generateIndex(node)
  of PyAugAssign:
    result = generator.generateAugAssign(node)
  # of PyAdd:
  #   result = generator.generateOp(node)
  # of PySub:
  #   result = generator.generateOp(node)
  # of PyMult:
  #   result = generator.generateOp(node)
  # of PyFloorDiv:
  #   result = generator.generateOp(node)
  of Slice:
    result = generator.generateSlice(node)
  of NimCommentedOut:
    result = generator.generateCommentedOut(node)
  of Continue:
    result = generator.generateContinue(node)
  of Class:
    result = generator.generateClass(node)
  else:
    log fmt"? {node.kind}"
    result = emptyNode

proc generate*(generator: var Generator, module: Module): string =
  generator.module = module
  generator.res = newNode(nkStmtList)

  if len(module.imports) > 0:
    generator.res.add(generator.generateImports(module.imports))

  for t in module.classes:
    generator.res.add(generator.generateClass(t))

  var forward: seq[Node] = @[]

  # for z, function in module.functions:
  #   # TODO: smart
  #   if not function.isIterator:
  #     for index, previous in module.functions:
  #       if index >= z:
  #         break
  #       if isValid(previous.calls) and previous.calls.contains(function.typ.label):
  #         forward.add(function)

  # for function in forward:
  #   generator.res.add(generator.generateForward(function))

  # for function in module.functions:
  #   generator.res.add(generator.generateFunction(function))

  for b in module.main:
    generator.res.add(emitNode(b))

  result = generator.res.renderTree({renderDocComments}) & "\n"
  #if result.startsWith("  "):
  #  result = result.splitLines().mapIt(if len(it) > 2: it[2..^1] else: it).join("\n")
