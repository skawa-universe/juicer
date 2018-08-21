import "dart:mirrors";
import "package:juicer/juicer.dart";
import "package:juicer/metadata.dart";

class JuicerError extends Error {
  JuicerError(this.message);

  @override
  String toString() => "JuicerError($message)";
  final String message;
}

abstract class PropertyAccessor {
  String get name;
  TypeMirror get getterType;
  TypeMirror get setterType;
  void setValue(InstanceMirror instance, dynamic value);
  dynamic getValue(InstanceMirror instance);
}

class FieldAccessor extends PropertyAccessor {
  FieldAccessor(this.name, this.variableMirror);

  TypeMirror get getterType => variableMirror.type;
  TypeMirror get setterType => variableMirror.isFinal || variableMirror.isConst ? null : variableMirror.type;

  void setValue(InstanceMirror instance, dynamic value) => instance.setField(variableMirror.simpleName, value);

  dynamic getValue(InstanceMirror instance) => instance.getField(variableMirror.simpleName);

  final String name;
  final VariableMirror variableMirror;
}

String _fieldNameFromMethodProperty(MethodMirror getterOrSetter) {
  String name = MirrorSystem.getName(getterOrSetter.simpleName);
  return getterOrSetter.isSetter ? name.substring(0, name.length - 1) : name;
}

class MethodPropertyAccessor extends PropertyAccessor {
  MethodPropertyAccessor(this.name, this.getter, this.setter)
      : fieldName = new Symbol(_fieldNameFromMethodProperty(getter ?? setter));

  TypeMirror get getterType => getter?.returnType;
  TypeMirror get setterType => setter?.parameters?.first?.type;

  void setValue(InstanceMirror instance, dynamic value) => instance.setField(fieldName, value);

  dynamic getValue(InstanceMirror instance) => instance.getField(fieldName);

  final String name;
  final Symbol fieldName;
  final MethodMirror getter;
  final MethodMirror setter;
}

Property _combineMetadata(Iterable<DeclarationMirror> mirror) {
  DeclarationMirror first = mirror.first;
  String fieldNameAsString =
      first is MethodMirror ? _fieldNameFromMethodProperty(first) : MirrorSystem.getName(first.simpleName);
  bool ignore = fieldNameAsString.startsWith("_");
  Property result = new Property(name: fieldNameAsString, ignore: ignore);
  for (Property p
      in mirror.expand((m) => m?.metadata ?? []).map((meta) => meta.reflectee).where((meta) => meta is Property)) {
    if (p.name != null) {
      if (p.ignore != null) {
        result = p;
      } else {
        result = result.withName(p.name);
      }
    } else if (p.ignore != null) {
      result = result.withIgnore(p.ignore);
    }
  }
  return result;
}

class MapperBuilder {
  List<PropertyAccessor> addClass(ClassMirror type, {bool requireJuiced: true}) {
    if (requireJuiced && !type.metadata.any((instance) => instance.reflectee is Juiced)) return [];
    Set<Symbol> processedAccessors = new Set();
    final Map<Symbol, DeclarationMirror> declarations = type.declarations;
    for (Symbol fieldName in declarations.keys) {
      final DeclarationMirror declaration = declarations[fieldName];
      PropertyAccessor accessor;
      if (declaration is VariableMirror) {
        if (declaration.isStatic) continue;
        Property p = _combineMetadata([declaration]);
        if (!p.ignore) accessor = new FieldAccessor(p.name, declaration);
      } else if (declaration is MethodMirror) {
        if (processedAccessors.contains(declaration.simpleName)) continue;
        if (declaration.isStatic || !declaration.isGetter && !declaration.isSetter) continue;
        String rawName = _fieldNameFromMethodProperty(declaration);
        MethodMirror getter;
        MethodMirror setter;
        if (declaration.isSetter) {
          setter = declaration;
          getter = declarations[new Symbol(rawName)];
        } else {
          getter = declaration;
          setter = declarations[new Symbol("$rawName=")];
        }
        Property p = _combineMetadata([getter, setter]);
        if (!p.ignore) accessor = new MethodPropertyAccessor(p.name, getter, setter);
      }
      if (accessor != null) accessors.add(accessor);
    }
    return accessors;
  }

  List<PropertyAccessor> accessors = [];
}

class MirrorClassMapper<T> extends ClassMapper<T> {
  factory MirrorClassMapper() => MirrorClassMapper<T>.forClass(T);

  factory MirrorClassMapper.forClass(Type t) => MirrorClassMapper<T>._forClassMirror(reflectClass(t));

  MirrorClassMapper._forClassMirror(this.mirror)
      : _accessors = new List.unmodifiable(new MapperBuilder().addClass(mirror)),
        _constructor = _findConstructor(mirror);

  Map<String, dynamic> toMap(Juicer juicer, T val) {
    Map<String, dynamic> result = {};
    InstanceMirror instance = reflect(val);
    for (PropertyAccessor accessor in _accessors) {
      if (accessor.getterType != null) {
        result[accessor.name] = juicer.encode(accessor.getValue(instance));
      }
    }
    return result;
  }

  T fromMap(Juicer juicer, Map<String, dynamic> map, T empty) {
    InstanceMirror instance = reflect(empty);
    for (PropertyAccessor accessor in _accessors) {
      if (accessor.setterType == null) continue;
      dynamic value = map[accessor.name];
      dynamic mappedValue;
      ClassMapper mapper = juicer.getMapper(value.runtimeType);
      if (mapper != null) {
        if (mapper is MirrorClassMapper) {
          mappedValue = juicer.decode(value, (_) => mapper.newInstance());
        } else {
          throw JuicerError("Unknown mapper class:"
              " ${mapper.runtimeType} ($mapper)");
        }
      } else if (value is Map) {
        TypeMirror setterType = accessor.setterType;
        if (setterType is ClassMirror && setterType.isSubclassOf(mapClass)) {
          ClassMapper mapper = juicer.getMapper(setterType.typeArguments[1].reflectedType);
          dynamic map = setterType.newInstance(_findConstructor(setterType).constructorName, []).reflectee;
          if (mapper != null) {
            if (mapper is MirrorClassMapper) {
              mappedValue = juicer.decodeMap(value, (_) => mapper.newInstance(), map);
            } else {
              throw JuicerError("Unknown mapper class:"
                  " ${mapper.runtimeType} ($mapper)");
            }
          } else {
            mappedValue = juicer.decodeMap(value, null, map);
          }
        }
      } else if (value is Iterable) {
        TypeMirror setterType = accessor.setterType;
        if (setterType is ClassMirror && setterType.isSubclassOf(iterableClass)) {
          ClassMapper mapper = juicer.getMapper(setterType.typeArguments[1].reflectedType);
          dynamic list;
          if (setterType.isSubclassOf(listClass)) {
            list = setterType.newInstance(_findConstructor(setterType).constructorName, []).reflectee;
          } else {
            list = setterType.newInstance(_findConstructor(setterType, "empty").constructorName, []).reflectee.toList();
          }
          if (mapper != null) {
            if (mapper is MirrorClassMapper) {
              mappedValue = juicer.decodeIterable(value, (_) => mapper.newInstance(), list);
            } else {
              throw JuicerError("Unknown mapper class:"
                  " ${mapper.runtimeType} ($mapper)");
            }
          } else {
            mappedValue = juicer.decodeIterable(value, null, list);
          }
        }
      } else {
        mappedValue = juicer.decode(value, null);
      }
      accessor.setValue(instance, mappedValue);
    }
    return instance.reflectee;
  }

  T newInstance() => mirror.newInstance(_constructor.constructorName, []) as T;

  static MethodMirror _findConstructor(ClassMirror type, [String preferred = ""]) {
    MethodMirror candidate;
    for (DeclarationMirror mirror in type.declarations.values.where((m) => m is MethodMirror && m.isConstructor)) {
      MethodMirror mm = mirror;
      bool noRequired = !mm.parameters.any((p) => !p.isOptional);
      if (noRequired && candidate != null) {
        if (candidate.parameters.isEmpty && mm.parameters.isNotEmpty) continue;
        if (MirrorSystem.getName(candidate.constructorName) == preferred &&
            candidate.parameters.isEmpty == mm.parameters.isEmpty) continue;
      }
      if (noRequired) candidate = mm;
    }
    return candidate;
  }

  final ClassMirror mirror;
  final List<PropertyAccessor> _accessors;
  final MethodMirror _constructor;

  static final ClassMirror mapClass = reflectClass(Map);
  static final ClassMirror listClass = reflectClass(List);
  static final ClassMirror iterableClass = reflectClass(Iterable);
}

Juicer createJuicerForLibraries({bool packageUriFilter(Uri uri)}) {
  MirrorSystem mirrorSystem = currentMirrorSystem();
  Map<Uri, LibraryMirror> libraries = mirrorSystem.libraries;
  Iterable<Uri> uris = libraries.keys;
  if (packageUriFilter != null) uris = uris.where(packageUriFilter);
  Map<Type, ClassMapper> classes = {};
  for (Uri libUri in uris) {
    for (DeclarationMirror dm in libraries[libUri].declarations.values) {
      if (dm is! ClassMirror) continue;
      if (!dm.metadata.any((meta) => meta.reflectee is Juiced)) continue;
      Type type = (dm as ClassMirror).reflectedType;
      classes[type] = new MirrorClassMapper.forClass(type);
    }
  }
  return new Juicer(new Map.unmodifiable(classes));
}
