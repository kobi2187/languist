# var suiteLabel = ""

# rewrite do (x: Any, y: Class, z: Method):
#   x.describe(y, z)
# do:
#   code:
#     suiteLabel = args["y"].label
#     command(variable("suite"), Node(kind: String, text: args["y"].label), Node(kind: Code, children: args["z"].code), VoidType)

# rewrite do (x: Any, y: Method):
#   subject(x, y)
# do:
#   code:
#     assign(variable(args["x"].text), Node(kind: Call, children: @[variable(suiteLabel)], typ: Type(kind: T.Simple, label: suiteLabel)), Var)


rewrite "RuboCop::AST::*", Type(kind: T.Simple, label: "Node")

# rewrite do (a: String, b: Method):
#   it(a, b)
# do:
#   code:
#     Node(kind: MacroCall, children: @[variable("test"), args["a"], Node(kind: Code, children: args["b"].code)], typ: VoidType)

# rewrite do (x: String, y: String):
#   def_node_matcher(x, y)
# do:
#   code:
#     var res = Node(kind: MacroCall, children: @[variable("nodeMatcher"), variableGenBlock(args["x"].text), args["y"]], typ: VoidType)
#     edump rewrites[1].genBlock
#     res

# # my mistake
# rewrite do (x: Symbol, y: String):
#   def_node_matcher(x, y)
# do:
#   code:
#     var res = Node(kind: MacroCall, children: @[variable("nodeMatcher"), variableGenBlock(args["x"].text), args["y"]], typ: VoidType)
#     # dump rewrites[1].genBlock
#     res

# rewrite do (a: Any):
#   a["ExcludedMethods"]
# do:
#   code:
#     attribute(args["a"], "ExcludedMethods", sequenceType(StringType))

# # we need this for : Node
# var NodeType* = Type(kind: Simple, label: "Node")

# rewrite do (a: Node):
#   a.`type`
# do:
#   code:
#     var arg = args["a"]
#     attribute(arg, "kind", Type(kind: Simple, label: "Type"))

const LOCATIONS = @["name", "expression", "selector", "nameRange", "operator", "keyword"]
const KINDS = @["lvasgn", "int", "def", "sym", "or_asgn", "begin"]

symbols:
  add_offense LOCATIONS:
    variable(a)

  _ KINDS:
    variable("Rb" & a.camelCase.capitalizeAscii)

params({"self": "*", "node": "Node"}.toTable)
