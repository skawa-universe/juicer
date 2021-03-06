// ignore_for_file: omit_local_variable_types

import 'dart:mirrors';
import 'package:juicer/juicer.dart';
import 'package:juicer/metadata.dart';

class JuicerError extends Error {
  JuicerError(this.message, [this.cause]);

  @override
  String toString() =>
      cause == null ? 'JuicerError($message)' : 'JuicerError($message: $cause)';
  final String message;
  final Object cause;
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

  @override
  TypeMirror get getterType => variableMirror.type;

  @override
  TypeMirror get setterType => variableMirror.isFinal || variableMirror.isConst
      ? null
      : variableMirror.type;

  @override
  void setValue(InstanceMirror instance, dynamic value) {
    try {
      instance.setField(variableMirror.simpleName, value);
    } catch (e) {
      throw JuicerError('Setting $name failed', e);
    }
  }

  @override
  dynamic getValue(InstanceMirror instance) =>
      instance.getField(variableMirror.simpleName).reflectee;

  @override
  final String name;
  final VariableMirror variableMirror;
}

String _fieldNameFromMethodProperty(MethodMirror getterOrSetter) {
  String name = MirrorSystem.getName(getterOrSetter.simpleName);
  return getterOrSetter.isSetter ? name.substring(0, name.length - 1) : name;
}

class MethodPropertyAccessor extends PropertyAccessor {
  MethodPropertyAccessor(this.name, this.getter, this.setter)
      : fieldName = Symbol(_fieldNameFromMethodProperty(getter ?? setter));

  @override
  TypeMirror get getterType => getter?.returnType;

  @override
  TypeMirror get setterType => setter?.parameters?.first?.type;

  @override
  void setValue(InstanceMirror instance, dynamic value) {
    try {
      instance.setField(fieldName, value);
    } catch (e) {
      throw JuicerError('Setting $name failed', e);
    }
  }

  @override
  dynamic getValue(InstanceMirror instance) =>
      instance.getField(fieldName).reflectee;

  @override
  final String name;
  final Symbol fieldName;
  final MethodMirror getter;
  final MethodMirror setter;
}

Property _combineMetadata(Iterable<DeclarationMirror> mirror) {
  mirror = mirror.where((m) => m != null);
  DeclarationMirror first = mirror.first;
  String fieldNameAsString = first is MethodMirror
      ? _fieldNameFromMethodProperty(first)
      : MirrorSystem.getName(first.simpleName);
  bool ignore = fieldNameAsString.startsWith('_');
  Property result = Property(name: fieldNameAsString, ignore: ignore);
  for (Property p in mirror
      .expand((m) => m?.metadata ?? [])
      .map((meta) => meta.reflectee)
      .whereType<Property>()) {
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
  List<PropertyAccessor> addClass(ClassMirror type,
      {bool requireJuiced = true}) {
    if (requireJuiced &&
        !type.metadata.any((instance) => instance.reflectee is Juiced)) {
      return [];
    }
    Set<Symbol> processedAccessors = {};
    final Map<Symbol, DeclarationMirror> declarations = type.declarations;
    for (Symbol fieldName in declarations.keys) {
      final DeclarationMirror declaration = declarations[fieldName];
      PropertyAccessor accessor;
      if (declaration is VariableMirror) {
        if (declaration.isStatic) continue;
        Property p = _combineMetadata([declaration]);
        if (!p.ignore) accessor = FieldAccessor(p.name, declaration);
      } else if (declaration is MethodMirror) {
        if (processedAccessors.contains(declaration.simpleName)) continue;
        if (declaration.isStatic ||
            !declaration.isGetter && !declaration.isSetter) continue;
        String rawName = _fieldNameFromMethodProperty(declaration);
        MethodMirror getter;
        MethodMirror setter;
        if (declaration.isSetter) {
          setter = declaration;
          getter = declarations[Symbol(rawName)];
        } else {
          getter = declaration;
          setter = declarations[Symbol('$rawName=')];
        }
        Property p = _combineMetadata([getter, setter]);
        if (!p.ignore) {
          accessor = MethodPropertyAccessor(p.name, getter, setter);
        }
      }
      if (accessor != null) accessors.add(accessor);
    }
    return accessors;
  }

  List<PropertyAccessor> accessors = [];
}

class MirrorClassMapper<T> extends ClassMapper<T> {
  factory MirrorClassMapper({bool requireJuiced = true}) =>
      MirrorClassMapper<T>.forClass(T, requireJuiced: requireJuiced);

  factory MirrorClassMapper.forClass(Type t, {bool requireJuiced = true}) =>
      MirrorClassMapper._forClassMirror(reflectClass(t),
          requireJuiced: requireJuiced);

  MirrorClassMapper._forClassMirror(this.mirror, {bool requireJuiced = true})
      : _accessors = List.unmodifiable(
            MapperBuilder().addClass(mirror, requireJuiced: requireJuiced)),
        _constructor = _findConstructor(mirror) {
    if (_constructor == null) {
      throw JuicerError(
          'Could not find usable constructor for ${mirror.qualifiedName}');
    }
  }

  @override
  Map<String, dynamic> toMap(Juicer juicer, T val) {
    Map<String, dynamic> result = {};
    InstanceMirror instance = reflect(val);
    for (PropertyAccessor accessor in _accessors) {
      if (accessor.getterType != null) {
        final dynamic value = accessor.getValue(instance);
        if (value is Map) {
          result[accessor.name] = Map.fromIterable(value.keys,
              value: (k) => juicer.encode(value[k]));
        } else if (value is Iterable) {
          result[accessor.name] = value.map((v) => juicer.encode(v)).toList();
        } else if (value is! String && value is! bool && value != null) {
          result[accessor.name] = juicer.encode(value);
        } else if (value != null) {
          result[accessor.name] = value;
        }
      }
    }
    return result;
  }

  @override
  T fromMap(Juicer juicer, Map map, T empty) {
    InstanceMirror instance = reflect(empty);
    for (PropertyAccessor accessor in _accessors) {
      if (accessor.setterType == null || !map.containsKey(accessor.name)) {
        continue;
      }
      dynamic value = map[accessor.name];
      dynamic mappedValue;
      ClassMapper mapper = juicer.getMapper(accessor.setterType.reflectedType);
      if (mapper != null) {
        if (mapper is MirrorClassMapper) {
          mappedValue = juicer.decode(value, (_) => mapper.newInstance());
        } else {
          throw JuicerError('Unknown mapper class:'
              ' ${mapper.runtimeType} ($mapper)');
        }
      } else if (value is Map) {
        TypeMirror setterType = accessor.setterType;
        if (setterType is ClassMirror && isMap(setterType)) {
          ClassMapper mapper =
              juicer.getMapper(setterType.typeArguments[1].reflectedType);
          dynamic map = setterType.newInstance(
              _findConstructor(setterType).constructorName, []).reflectee;
          if (mapper != null) {
            mappedValue =
                juicer.decodeMap(value, (_) => mapper.newInstance(), map);
          } else {
            mappedValue = juicer.decodeMap(value, null, map);
          }
        }
      } else if (value is Iterable) {
        TypeMirror setterType = accessor.setterType;
        if (setterType is ClassMirror && isIterable(setterType)) {
          ClassMapper mapper =
              juicer.getMapper(setterType.typeArguments[0].reflectedType);
          dynamic list;
          if (setterType.isSubclassOf(listClass)) {
            list = setterType.newInstance(
                _findConstructor(setterType).constructorName, []).reflectee;
          } else {
            MethodMirror ctor = _findConstructor(setterType, 'empty');
            if (ctor != null) {
              list = setterType
                  .newInstance(ctor.constructorName, [])
                  .reflectee
                  .toList();
            } else {
              list = setterType
                  .newInstance(Symbol('generate'), [0, (_) => null])
                  .reflectee
                  .toList();
            }
          }
          if (mapper != null) {
            mappedValue =
                juicer.decodeIterable(value, (_) => mapper.newInstance(), list);
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

  @override
  T newInstance() =>
      mirror.newInstance(_constructor.constructorName, []).reflectee as T;

  static MethodMirror _findConstructor(ClassMirror type,
      [String preferred = '']) {
    MethodMirror candidate;
    for (DeclarationMirror mirror in type.declarations.values
        .where((m) => m is MethodMirror && m.isConstructor)) {
      MethodMirror mm = mirror;
      if (type.isAbstract && !mm.isFactoryConstructor) continue;
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

  Set<Type> referencedTypes() {
    Set<Type> referred = {};
    for (PropertyAccessor accessor in _accessors) {
      addReferredTypes(referred, accessor.getterType);
      addReferredTypes(referred, accessor.setterType);
    }
    return referred;
  }

  static void addReferredTypes(Set<Type> types, TypeMirror t) {
    Type rawType = t.reflectedType;
    // ignore primitive types
    if (rawType == int ||
        rawType == double ||
        rawType == bool ||
        rawType == String ||
        rawType == Object ||
        rawType == Null) return;
    if (t is ClassMirror) {
      if (isMap(t)) {
        addReferredTypes(types, t.typeArguments[1]);
      } else if (isIterable(t)) {
        addReferredTypes(types, t.typeArguments[0]);
      } else {
        types.add(t.reflectedType);
      }
    }
  }

  @override
  String toString() => mirror.simpleName.toString();

  final ClassMirror mirror;
  final List<PropertyAccessor> _accessors;
  final MethodMirror _constructor;

  static bool isIterable(TypeMirror type) =>
      type is ClassMirror &&
      (type.isSubclassOf(iterableClass) ||
          type.superinterfaces.any((i) => i.isSubclassOf(iterableClass)));

  static bool isMap(TypeMirror type) =>
      type is ClassMirror && type.isSubclassOf(mapClass);

  static final ClassMirror mapClass = reflectClass(Map);
  static final ClassMirror listClass = reflectClass(List);
  static final ClassMirror iterableClass = reflectClass(Iterable);
}

/// Juices a collection of [classes].
///
/// Will not juice the referenced classes if [juiceReferenced] is set to `false`
/// (the default is `true`).
///
/// Will require the `@juiced` annotation on all the classes if [requireJuiced]
/// is set to `true` (the default is `false`)
Juicer juiceClasses(Iterable<Type> classes,
    {bool juiceReferenced = true, bool requireJuiced = false}) {
  Set<Type> referenced = {};
  Map<Type, ClassMapper> mappers = {};
  while (true) {
    for (Type type in classes) {
      MirrorClassMapper mapper =
          MirrorClassMapper.forClass(type, requireJuiced: requireJuiced);
      mappers[type] = mapper;
      if (juiceReferenced) referenced.addAll(mapper.referencedTypes());
    }
    if (!juiceReferenced) break;
    referenced.removeAll(mappers.keys);
    if (referenced.isEmpty) break;
    classes = referenced;
  }
  return Juicer(Map.unmodifiable(mappers));
}

/// Juices the libraries with the names in [libraries].
///
/// For example if every juicable class is in a `comm` package
/// `juiceLibraries(['comm'])` will return a juicer for that package.
Juicer juiceLibraries(Iterable<String> libraries) {
  Set<String> libSet = libraries.toSet();
  return createJuicerForLibraries(
      packageUriFilter: (uri) =>
          uri.scheme == 'package' &&
          uri.pathSegments.isNotEmpty &&
          libSet.contains(uri.pathSegments.first));
}

/// Enumerates all the libraries and looks for `@juiced` classes.
///
/// The libraries may be filtered by package URI using [packageUriFilter].
Juicer createJuicerForLibraries({bool Function(Uri uri) packageUriFilter}) {
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
      classes[type] = MirrorClassMapper.forClass(type);
    }
  }
  return Juicer(Map.unmodifiable(classes));
}
