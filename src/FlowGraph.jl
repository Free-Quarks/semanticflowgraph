module FlowGraph
export MonoclElem, RawNode, RawPort, RawNodeAnnotationKind,
  read_raw_graph, read_raw_graph_file,
  read_semantic_graph, read_semantic_graph_file, to_semantic_graph

using Base.Iterators: product

using AutoHashEquals, Parameters
import LightXML
using LightGraphs

using Catlab.Diagram
using ..Doctrine
using ..Ontology

# Raw flow graph
################

@enum(RawNodeAnnotationKind,
  FunctionAnnotation = 0,
  ConstructAnnotation = 1,
  SlotAnnotation = 2)

function Base.convert(::Type{RawNodeAnnotationKind}, s::String)
  if (s == "function") FunctionAnnotation
  elseif (s == "construct") ConstructAnnotation
  elseif (s == "slot") SlotAnnotation
  else error("Unknown annotation kind \"$s\"") end
end

@with_kw struct RawNode
  language::Dict{String,Any} = Dict{String,Any}()
  annotation::Nullable{String} = Nullable{String}()
  annotation_index::Nullable{Int} = Nullable()
  annotation_kind::RawNodeAnnotationKind = FunctionAnnotation
end

@with_kw struct RawPort
  language::Dict{String,Any} = Dict{String,Any}()
  annotation::Nullable{String} = Nullable{String}()
  annotation_index::Nullable{Int} = Nullable()
  id::Nullable{String} = Nullable{String}()
  value::Nullable = Nullable()
end

# GraphML support.

""" Read raw flow graph from GraphML.
"""
function read_raw_graph(xdoc::LightXML.XMLDocument)
  GraphML.read_graphml(RawNode, RawPort, Void, xdoc)
end
read_raw_graph(xml::String) = read_raw_graph(LightXML.parse_string(xml))
read_raw_graph_file(args...) = read_raw_graph(LightXML.parse_file(args...))

function GraphML.convert_from_graphml_data(::Type{RawNode}, data::Dict)
  annotation = Nullable{String}(pop!(data, "annotation", nothing))
  annotation_index = Nullable{Int}(pop!(data, "annotation_index", nothing))
  annotation_kind_str = Nullable{String}(pop!(data, "annotation_kind", nothing))
  annotation_kind = isnull(annotation_kind_str) ? FunctionAnnotation :
    convert(RawNodeAnnotationKind, get(annotation_kind_str))
  RawNode(data, annotation, annotation_index, annotation_kind)
end

function GraphML.convert_from_graphml_data(::Type{RawPort}, data::Dict)
  annotation = Nullable{String}(pop!(data, "annotation", nothing))
  annotation_index = Nullable{Int}(pop!(data, "annotation_index", nothing))
  id = Nullable{String}(pop!(data, "id", nothing))
  value = pop!(data, "value", Nullable())
  RawPort(data, annotation, annotation_index, id, value)
end

# Graphviz support.

function GraphvizWiring.node_label(node::RawNode)
  # FIXME: "qual_name" is Python-specific. Standarize some of these attributes?
  lang = node.language
  get(lang, "qual_name", get(lang, "name", "?"))
end

function GraphvizWiring.edge_label(port::RawPort)
  lang = port.language
  get(lang, "qual_name", get(lang, "name", ""))
end

# Semantic flow graph
#####################

""" Object in the Monocl category of elements.
"""
@auto_hash_equals struct MonoclElem
  ob::Nullable{Monocl.Ob}
  id::Nullable{String}
  value::Nullable
end
MonoclElem(ob; id=Nullable{String}(), value=Nullable()) = MonoclElem(ob, id, value)

# GraphML support.

""" Read semantic flow graph from GraphML.
"""
function read_semantic_graph(xdoc::LightXML.XMLDocument; elements::Bool=true)
  GraphML.read_graphml(
    Nullable{Monocl.Hom},
    !elements ? Nullable{Monocl.Ob} : MonoclElem,
    Void, xdoc)
end
function read_semantic_graph(xml::String; kw...)
  read_semantic_graph(LightXML.parse_string(xml); kw...)
end
function read_semantic_graph_file(args...; kw...)
  read_semantic_graph(LightXML.parse_file(args...); kw...)
end

function GraphML.convert_from_graphml_data(::Type{MonoclElem}, data::Dict)
  ob = haskey(data, "ob") ?
    parse_json_sexpr(Monocl, data["ob"]; symbols=false) : nothing
  id = get(data, "id", nothing)
  value = get(data, "value", Nullable())
  MonoclElem(ob, id, value)
end

function GraphML.convert_to_graphml_data(elem::MonoclElem)
  data = Dict{String,Any}()
  if (!isnull(elem.ob)) data["ob"] = to_json_sexpr(get(elem.ob)) end
  if (!isnull(elem.id)) data["id"] = get(elem.id) end
  if (!isnull(elem.value)) data["value"] = get(elem.value) end
  return data
end

# Semantic enrichment algorithm.

""" Convert a raw flow graph into a semantic flow graph.
"""
function to_semantic_graph(db::OntologyDB, raw::WiringDiagram;
                           elements::Bool=true)::WiringDiagram
  sem = WiringDiagram(to_semantic_ports(db, input_ports(raw)),
                      to_semantic_ports(db, output_ports(raw)))
  
  # Add boxes.
  to_substitute = Int[]
  for v in box_ids(raw)
    raw_box = box(raw, v)
    sem_box = to_semantic_graph(db, raw_box; elements=elements)
    @assert add_box!(sem, sem_box) == v
    if isa(raw_box, Box) && isa(sem_box, WiringDiagram)
      # If the raw box is atomic but the semantic box is a wiring diagram,
      # we should expand it by substitution. We defer the substitution until
      # later so that the box IDs on the wires remain valid.
      push!(to_substitute, v)
    end    
  end
  
  # Add wires.
  # FIXME: If a raw box expands to a semantic box that is missing a port with
  # incoming or outoging wires in the raw graph (e.g., when an unannotated
  # keyword argument is passed), this logic will fail. We should detect this
  # situation and either raise an informative error or discard the wire.
  add_wires!(sem, wires(raw))
  
  # Perform deferred substitutions (see above).
  substitute!(sem, to_substitute)
  
  # Simplify the diagram by collapsing adjacent unannotated boxes.
  collapse_unannotated_boxes!(sem)
  
  return sem
end

function to_semantic_graph(db::OntologyDB, raw_box::Box{RawNode}; kw...)::AbstractBox
  if isnull(raw_box.value.annotation)
    Box(nothing,
        to_semantic_ports(db, input_ports(raw_box)),
        to_semantic_ports(db, output_ports(raw_box)))
  else
    expand_annotated_box(db, raw_box)
  end
end

function to_semantic_ports(db::OntologyDB, ports::Vector{RawPort})
  [ isnull(port.annotation) ? nothing : expand_annotated_port(db, port)
    for port in ports ]
end

""" Expand a single annotated box from a raw flow graph.
"""
function expand_annotated_box(db::OntologyDB, raw_box::Box{RawNode})::WiringDiagram
  expand_annotated_box(db, raw_box, Val{raw_box.value.annotation_kind})
end

function expand_annotated_box(db::OntologyDB, raw_box::Box{RawNode},
                              ::Type{Val{FunctionAnnotation}})
  inputs = input_ports(raw_box)
  outputs = output_ports(raw_box)
  note = load_annotation(db, get(raw_box.value.annotation))::HomAnnotation
  f = WiringDiagram(inputs, outputs)
  v = add_box!(f, to_wiring_diagram(note.definition))
  add_wires!(f, ((input_id(f), i) => (v, get(port.annotation_index))
                 for (i, port) in enumerate(inputs)
                 if !isnull(port.annotation_index)))
  add_wires!(f, ((v, get(port.annotation_index)) => (output_id(f), i)
                 for (i, port) in enumerate(outputs)
                 if !isnull(port.annotation_index)))
  substitute!(f, v)
  return f
end

function expand_annotated_box(db::OntologyDB, raw_box::Box{RawNode},
                              ::Type{Val{ConstructAnnotation}})
  note = load_annotation(db, get(raw_box.value.annotation))::ObAnnotation
  to_wiring_diagram(construct(note.definition))
end

function expand_annotated_box(db::OntologyDB, raw_box::Box{RawNode},
                              ::Type{Val{SlotAnnotation}})
  note = load_annotation(db, get(raw_box.value.annotation))::ObAnnotation
  index = get(raw_box.value.annotation_index)
  to_wiring_diagram(note.slots[index])
end

""" Expand a single annotated port from a raw flow graph.
"""
function expand_annotated_port(db::OntologyDB, raw_port::RawPort)::Monocl.Ob
  note = load_annotation(db, get(raw_port.annotation))::ObAnnotation
  note.definition
end

""" Collapse adjacent unannotated boxes into single boxes.
"""
function collapse_unannotated_boxes!(diagram::WiringDiagram)
  graph = Wiring.graph(diagram)
  closure = transitiveclosure(graph)
  
  nonboxes = (input_id(diagram), output_id(diagram))
  is_annotated(v::Int) = !(v in nonboxes) && box(diagram,v).value != nothing
  is_unannotated(v::Int) = !(v in nonboxes) && box(diagram,v).value == nothing
  annotated_ancestors(v::Int) = filter(is_annotated, in_neighbors(closure, v))
  annotated_descendants(v::Int) = filter(is_annotated, out_neighbors(closure, v))

  to_collapse = Graph(nv(graph))
  for parent in 1:nv(graph)
    for child in out_neighbors(graph, parent)
      if (is_unannotated(parent) && is_unannotated(child) &&
          all(has_edge(closure, u, v)
              for (u,v) in product(annotated_ancestors(child),
                                   annotated_descendants(parent))))
        add_edge!(to_collapse, parent, child)
      end
    end
  end
  
  # Encapsulate connected sub-diagrams of unannotated boxes. Include even
  # components of size 1 because encapsulation will simplify the ports.
  components = [ c for c in connected_components(to_collapse)
                 if length(c) > 1 || is_unannotated(first(c)) ]
  encapsulate!(diagram, components, nothing)
  return diagram
end

end
