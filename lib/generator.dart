import "dart:async";
import "dart:convert";
import "package:analyzer/src/generated/engine.dart" show AnalysisContext;
import "package:analyzer/dart/element/element.dart";
import "package:analyzer/dart/element/type.dart";
import "package:analyzer/dart/constant/value.dart";
import "package:build/build.dart";
import "package:source_gen/source_gen.dart";

Builder juiceGenerator(BuilderOptions _) =>
    new LibraryBuilder(new JuiceGenerator(),
        additionalOutputExtensions: ["juiced"]);

class JuicerError extends Error {
  JuicerError(this.message);

  String toString() => message;

  final String message;
}

class _JuicedClass {
  _JuicedClass(this.mapperName, this.modelName, this.element) {
    ConstructorElement noParameterConstructor;
    for (ConstructorElement c in element.type.constructors) {
      if (c.name.startsWith("_")) continue;
      bool noRequiredParameters = !c.parameters.any((p) => p.isNotOptional);
      if (noRequiredParameters) {
        // we prefer a 0 parameter constructor primarily
        // we prefer the default constructor
        if (noParameterConstructor != null &&
            (noParameterConstructor.parameters.isEmpty &&
                    !(c.parameters.isEmpty && c.isDefaultConstructor) ||
                (noParameterConstructor.isDefaultConstructor &&
                    c.parameters.isNotEmpty))) continue;
        noParameterConstructor = c;
        if (c.isDefaultConstructor) break;
      }
    }
    if (noParameterConstructor == null) {
      throw new JuicerError("No constructor without required parameters"
          " found in ${element.displayName} (${element.location})");
    }
    _constructorSuffix = noParameterConstructor.isDefaultConstructor
        ? ""
        : ".${noParameterConstructor.name}";
  }

  static String _typeIdOf(Element element) =>
      "${JuiceGenerator._libraryUri(new LibraryReader(element.library))}"
      " ${element.name}";

  String get internalTypeId => _typeIdOf(element);

  String get instantiation => "$modelName$_constructorSuffix()";

  Map<String, _JuicedClass> mapperById;

  void writeMapper(StringBuffer buffer) {
    String name = mapperName;
    String typeName = modelName;
    buffer.writeln("class $name extends ClassMapper<$typeName> {");
    buffer.writeln("const $name();");
    buffer.writeln(
        "Map<String, dynamic> toMap(Juicer juicer, $typeName val) => {");
    Map<String, String> fieldNames = _fieldNames(element);
    for (final field in element.fields) {
      String fieldName = fieldNames[field.name];
      if (fieldName != null) {
        if (isLikeNum(field.type)) {
          _writeNumber(fieldName, field, buffer);
        } else if (isLikeIterable(field.type)) {
          buffer.writeln(
              "${_quote(fieldName)}: val.${field.name}?.map(juicer.encode)?.toList(),");
        } else if (isLikeMap(field.type)) {
          buffer.writeln("${_quote(fieldName)}: val.${field.name} == null "
              "? null "
              ": new Map.fromIterable(val.${field.name}.keys, "
              "value: (k) => juicer.encode(val.${field.name}[k])),");
        } else if (!isBool(field.type) && !isString(field.type)) {
          buffer.writeln(
              "${_quote(fieldName)}: juicer.encode(val.${field.name}),");
        } else {
          // bool, String will work just fine
          buffer.writeln("${_quote(fieldName)}: val.${field.name},");
        }
      } else {
        buffer.writeln("// ${field.name} is ignored");
      }
    }
    buffer.writeln("};");
    buffer.writeln("$typeName fromMap(Juicer juicer, "
        "Map<String, dynamic> map, $typeName empty) => empty");
    for (final field in element.fields) {
      String fieldName = fieldNames[field.name];
      if (fieldName != null) {
        if (isLikeNum(field.type)) {
          _readNumber(fieldName, field, buffer);
        } else if (isLikeIterable(field.type)) {
          String template = _templateBody(field, 0);
          buffer.writeln(
              "..${field.name} = juicer.decodeIterable(map[${_quote(fieldName)}], $template, ${_typeParameters(field.type)}[])");
        } else if (isLikeMap(field.type)) {
          String template = _templateBody(field, 1);
          buffer.writeln(
              "..${field.name} = juicer.decodeMap(map[${_quote(fieldName)}], $template, ${_typeParameters(field.type)}{})");
        } else if (!isBool(field.type) && !isString(field.type)) {
          String template = _templateBodyByType(field, field.type);
          buffer.writeln(
              "..${field.name} = juicer.decode(map[${_quote(fieldName)}], $template)");
        } else {
          // bool, String will work just fine
          buffer.writeln("..${field.name} = map[${_quote(fieldName)}]");
        }
      } else {
        buffer.writeln("// ${field.name} is ignored");
      }
    }
    buffer.writeln(";}");
  }

  String _typeParameters(DartType type) {
    if (type is ParameterizedType) {
      String list = type.typeArguments.map(_typeRef).join(",");
      return "<$list>";
    } else {
      return "";
    }
  }

  String _typeRef(DartType type) {
    _JuicedClass mapper = mapperById[_typeIdOf(type.element)];
    if (mapper != null) return mapper.modelName;
    return type.name;
  }

  String _templateBody(FieldElement field, int index) {
    if (field.type is! ParameterizedType) return "null";
    DartType type = (field.type as ParameterizedType).typeArguments[index];
    return _templateBodyByType(field, type);
  }

  String _templateBodyByType(FieldElement field, DartType type) {
    if (isDouble(type, context: field.context))
      return "(dynamic val) => val?.toDouble()";
    if (isInt(type, context: field.context))
      return "(dynamic val) => val?.toInt()";
    if (isString(type, context: field.context))
      return "(dynamic val) => val as String";
    if (isBool(type, context: field.context))
      return "(dynamic val) => val as bool";
    if (isNum(type, context: field.context))
      return "(dynamic val) => val as num";
    _JuicedClass mapper = mapperById[_typeIdOf(type.element)];
    if (mapper != null) return "(_) => ${mapper.instantiation}";
    return null;
  }

  static bool isLikeIterable(DartType type) {
    return type
        .isAssignableTo(type.element.context.typeProvider.iterableDynamicType);
  }

  static bool isLikeMap(DartType type) {
    final typeProvider = type.element.context.typeProvider;
    DartType jsonCompatibleMap = typeProvider.mapType
        .instantiate([typeProvider.stringType, typeProvider.dynamicType]);
    return type.isAssignableTo(jsonCompatibleMap);
  }

  static bool isString(DartType type, {AnalysisContext context}) {
    return type.isEquivalentTo(
        (context ?? type.element.context).typeProvider.stringType);
  }

  static bool isBool(DartType type, {AnalysisContext context}) {
    return type.isEquivalentTo(
        (context ?? type.element.context).typeProvider.boolType);
  }

  static bool isInt(DartType type, {AnalysisContext context}) {
    return type
        .isEquivalentTo((context ?? type.element.context).typeProvider.intType);
  }

  static bool isDouble(DartType type, {AnalysisContext context}) {
    return type.isEquivalentTo(
        (context ?? type.element.context).typeProvider.doubleType);
  }

  static bool isLikeNum(DartType type) {
    return type.isSubtypeOf(type.element.context.typeProvider.numType);
  }

  static bool isNum(DartType type, {AnalysisContext context}) {
    return type
        .isEquivalentTo((context ?? type.element.context).typeProvider.numType);
  }

  static Map<String, String> _fieldNames(ClassElement element) {
    Map<String, String> result = {};
    Map<String, List<PropertyAccessorElement>> accessorsByName = {};
    for (PropertyAccessorElement a in element.accessors) {
      (accessorsByName[a.displayName] ??= <PropertyAccessorElement>[]).add(a);
    }
    for (final field in element.fields) {
      if (field.isStatic) continue;
      List<Element> metadataSources = [field];
      metadataSources
          .addAll(accessorsByName[field.name] ?? <PropertyAccessorElement>[]);
      Iterable<ElementAnnotation> annotations =
          metadataSources.expand((s) => s.metadata);
      List<DartObject> propertyMetadata = annotations
          .map((a) => a.computeConstantValue())
          .where((m) => _isOwnObject(m, typeName: "Property"))
          .toList();
      bool defaultHidden = field.name.startsWith("_");
      bool ignored = propertyMetadata.isNotEmpty &&
              propertyMetadata
                  .any((m) => m.getField("ignore")?.toBoolValue() ?? false) ||
          defaultHidden;
      if (!ignored) {
        String alias = propertyMetadata
                .firstWhere((m) => m.getField("name")?.toStringValue() != null,
                    orElse: () => null)
                ?.getField("name")
                ?.toStringValue() ??
            field.name;
        result[field.name] = alias;
      }
    }
    return result;
  }

  static void _writeNumber(
      String fieldName, FieldElement field, StringBuffer buffer) {
    buffer.writeln("${_quote(fieldName)}: val.${field.name},");
  }

  static void _readNumber(
      String fieldName, FieldElement field, StringBuffer buffer) {
    String suffix;
    if (isInt(field.type)) {
      suffix = "?.toInt()";
    } else if (isDouble(field.type)) {
      suffix = "?.toDouble()";
    } else {
      suffix = "";
    }
    buffer.writeln("..${field.name} = map[${_quote(fieldName)}]$suffix");
  }

  static String _quote(String s) => JuiceGenerator._quote(s);

  static bool _isOwnObject(DartObject obj, {String typeName}) =>
      JuiceGenerator._isOwnObject(obj, typeName: typeName);

  static bool _isOwnType(ParameterizedType type) =>
      JuiceGenerator._isOwnType(type);

  static bool _isOwnUri(Uri uri) => JuiceGenerator._isOwnUri(uri);

  final String mapperName;
  final String modelName;
  final ClassElement element;
  String _constructorSuffix;
}

class JuiceGenerator extends Generator {
  const JuiceGenerator();

  @override
  Future<String> generate(LibraryReader library, BuildStep buildStep) async {
    final exports = library.element.exports;
    if (exports.isEmpty) return null;
    StringBuffer buffer = new StringBuffer();
    Map<String, _JuicedClass> mappers = {};
    Map<String, _JuicedClass> mapperByTypeId = {};
    Map<String, String> importAliases = {};
    int importCounter = 0;
    for (final e in exports) {
      LibraryReader reader = new LibraryReader(e.exportedLibrary);
      List<ClassElement> mappableClasses = reader.allElements
          .where(_elementIsMappable)
          .map((Element e) => e as ClassElement)
          .toList();
      for (ClassElement element in mappableClasses) {
        String name = "_\$${element.name}Juicer";
        if (mappers.containsKey(name)) {
          String prefix = name;
          for (int i = 0; i < 100; ++i) {
            name = "$prefix\$$i";
            if (!mappers.containsKey(name)) break;
          }
          if (mappers.containsKey(name)) {
            throw new JuicerError("Can't generate name for ${element.name}"
                " in ${element.location}");
          }
        }
        String importDecl = "import ${_quote(_libraryUri(library))}";
        String alias;
        if (importAliases.containsKey(importDecl)) {
          alias = importAliases[importDecl];
        } else {
          alias = importAliases[importDecl] = "_\$i${++importCounter}";
        }
        if (buffer.isEmpty) {
          buffer.writeln("import \"package:juicer/juicer.dart\";");
        }
        String typeName = "$alias.${element.name}";
        _JuicedClass mapper = new _JuicedClass(name, typeName, element);
        mappers[typeName] = mapper;
        mapperByTypeId[mapper.internalTypeId] = mapper;
      }
    }
    buffer
      ..write("// ")
      ..writeln(mapperByTypeId.keys.join("\n// "));
    for (_JuicedClass mapper in mappers.values) {
      mapper.mapperById = mapperByTypeId;
      mapper.writeMapper(buffer);
    }
    buffer.writeln("const Juicer juicer = const Juicer(const {");
    for (_JuicedClass mapper in mapperByTypeId.values) {
      buffer.writeln("${mapper.modelName}: const ${mapper.mapperName}(),");
    }
    buffer.writeln("});");
    String importDeclarations =
        importAliases.keys.map((k) => "$k as ${importAliases[k]};").join("\n");
    return "$importDeclarations\n$buffer";
  }

  static bool _elementIsMappable(Element element) =>
      element is ClassElement &&
      element.metadata
          .map((m) => m.computeConstantValue().type)
          .any((type) => _isOwnType(type) && type.name == "Juiced");

  static bool _isOwnObject(DartObject obj, {String typeName}) =>
      _isOwnType(obj.type) && (typeName == null || obj.type.name == typeName);

  static bool _isOwnType(ParameterizedType type) {
    return _isOwnUri(
        new LibraryReader(type.element.library).pathToElement(type.element));
  }

  static bool _isOwnUri(Uri uri) {
    return (uri.scheme == "asset" || uri.scheme == "package") &&
        uri.pathSegments.isNotEmpty &&
        uri.pathSegments.first == "juicer";
  }

  static String _libraryUri(LibraryReader library) =>
      library.pathToElement(library.element).toString();

  static String _quote(String s) {
    String js = json.encode(s);
    return js.replaceAll(r"$", r"\$");
  }
}
