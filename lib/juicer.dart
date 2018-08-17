import "dart:async";
import "dart:convert";
import "dart:mirrors";
import "package:analyzer/dart/element/element.dart";
import "package:analyzer/dart/element/type.dart";
import "package:analyzer/dart/constant/value.dart";
import "package:build/build.dart";
import "package:source_gen/source_gen.dart";

import "metadata.dart";

Builder juiceGenerator(BuilderOptions _) =>
    new LibraryBuilder(new JuiceGenerator(),
        additionalOutputExtensions: ["juiced"]);

class JuicerError extends Error {
  JuicerError(this.message);

  String toString() => message;

  final String message;
}

class _JuicedClass {
  _JuicedClass(this.mapperName, this.modelName, this.element);

  final String mapperName;
  final String modelName;
  final ClassElement element;
}

class JuiceGenerator extends Generator {
  const JuiceGenerator();

  @override
  Future<String> generate(LibraryReader library, BuildStep buildStep) async {
    final exports = library.element.exports;
    if (exports.isEmpty) return null;
    StringBuffer buffer = new StringBuffer();
    Map<String, _JuicedClass> mappers = {};
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
        String importDecl =
            "import ${_quote(library.pathToElement(library.element).toString())}";
        String alias;
        if (importAliases.containsKey(importDecl)) {
          alias = importAliases[importDecl];
        } else {
          alias = importAliases[importDecl] = "_\$i${++importCounter}";
        }
        if (buffer.isEmpty) {
          buffer.writeln("abstract class _Mapper<T> {");
          buffer.writeln("const _Mapper();");
          buffer.writeln("Map<String, dynamic> toMap(T val);");
          buffer.writeln("T fromMap(Map<String, dynamic> map, T empty);");
          buffer.writeln("}");
        }
        String typeName = "$alias.${element.name}";
        mappers[typeName] = new _JuicedClass(name, typeName, element);
        buffer.writeln("class $name extends _Mapper<$typeName> {");
        buffer.writeln("const $name();");
        buffer.writeln("Map<String, dynamic> toMap($typeName val) => {");
        Map<String, String> fieldNames = _fieldNames(element);
        for (final field in element.fields) {
          String fieldName = fieldNames[field.name];
          if (fieldName != null) {
            if (field.type is InterfaceType) {
              InterfaceType ift = field.type;
              buffer.writeln("// isBottom: ${ift.isBottom}");
              buffer.writeln("// isObject: ${ift.isObject}");
              buffer.writeln("// isUndefined: ${ift.isUndefined}");
              buffer.writeln("// isVoid: ${ift.isVoid}");
            }
            if (isLikeNum(field.type)) {
              _writeNumber(fieldName, field, buffer);
            } else {
              buffer.writeln("${_quote(fieldName)}: val.${field.name},");
            }
          } else {
            buffer.writeln("// ${field.name} is ignored");
          }
        }
        buffer.writeln("};");
        buffer.writeln(
            "$typeName fromMap(Map<String, dynamic> map, $typeName empty) => empty");
        for (final field in element.fields) {
          String fieldName = fieldNames[field.name];
          if (fieldName != null) {
            if (isLikeNum(field.type)) {
              _readNumber(fieldName, field, buffer);
            } else {
              buffer.writeln("..${field.name} = map[${_quote(fieldName)}]");
            }
          } else {
            buffer.writeln("// ${field.name} is ignored");
          }
        }
        buffer.writeln(";}");
      }
    }
    buffer.writeln("const Map<Type, _Mapper> _juicers = const {");
    for (String typeName in mappers.keys) {
      buffer.writeln("$typeName: const ${mappers[typeName].mapperName}(),");
    }
    buffer.writeln("};");
    String importDeclarations =
        importAliases.keys.map((k) => "$k as ${importAliases[k]};").join("\n");
    return "$importDeclarations\n$buffer";
  }

  static bool isLikeIterable(DartType type) {
    return type.isSubtypeOf(type.element.context.typeProvider.iterableType);
  }

  static bool isLikeList(DartType type) {
    return type.isSubtypeOf(type.element.context.typeProvider.listType);
  }

  static bool isLikeMap(DartType type) {
    return type.isSubtypeOf(type.element.context.typeProvider.mapType);
  }

  static bool isString(DartType type) {
    return type.isEquivalentTo(type.element.context.typeProvider.stringType);
  }

  static bool isBool(DartType type) {
    return type.isEquivalentTo(type.element.context.typeProvider.boolType);
  }

  static bool isInt(DartType type) {
    return type.isEquivalentTo(type.element.context.typeProvider.intType);
  }

  static bool isDouble(DartType type) {
    return type.isEquivalentTo(type.element.context.typeProvider.doubleType);
  }

  static bool isLikeNum(DartType type) {
    return type.isSubtypeOf(type.element.context.typeProvider.numType);
  }

  static bool isNum(DartType type) {
    return type.isEquivalentTo(type.element.context.typeProvider.numType);
  }

  static Map<String, String> _fieldNames(ClassElement element) {
    Map<String, String> result = {};
    Map<String, List<PropertyAccessorElement>> accessorsByName = {};
    for (PropertyAccessorElement a in element.accessors) {
      (accessorsByName[a.displayName] ??= <PropertyAccessorElement>[]).add(a);
    }
    for (final field in element.fields) {
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

  static String _quote(String s) {
    String js = json.encode(s);
    return js.replaceAll(r"$", r"\$");
  }

  void _writeNumber(String fieldName, FieldElement field, StringBuffer buffer) {
    buffer.writeln("${_quote(fieldName)}: val.${field.name},");
  }

  void _readNumber(String fieldName, FieldElement field, StringBuffer buffer) {
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
}
