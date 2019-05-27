import "dart:convert";

import "package:juicer/metadata.dart";

/// Juicer uses [ClassMapper]s to convert objects
/// of classes to and from map objects.
abstract class ClassMapper<T> {
  const ClassMapper();

  /// Converts an instance of class in [val] to a map using the [juicer]
  Map<String, dynamic> toMap(Juicer juicer, T val);

  /// Converts a [map] to an instance of the class by filling [empty] using [juicer].
  T fromMap(Juicer juicer, Map map, T empty);

  /// Creates a new instance of the class.
  T newInstance();
}

/// Creates an instance of a class which may or may not
/// be based on [valueToAdapt], the value that is being
/// decoded
typedef T AdaptingFactory<T>(dynamic valueToAdapt);

/// A `Juicer` instance is capable of decoding a set of types
class Juicer {
  /// Constructs a `Juicer` with a given set of class [mappers].
  /// Usually there's no need to call this directly.
  const Juicer(this.mappers);

  /// Combines this `Juicer` with [other] so the resulting juicer will be
  /// able to decode the union of the types (the mappers in [other] take
  /// precedence)
  Juicer combine(Juicer other) {
    Map<Type, ClassMapper> union = new Map.from(mappers);
    union.addAll(other.mappers);
    return new Juicer(new Map.unmodifiable(union));
  }

  /// Encodes [val] to JSON
  String encodeJson(dynamic val) {
    return json.encode(encode(val));
  }

  /// Decodes [val] as a JSON object, a [targetFactory] can be given
  /// if a type is expected.
  ///
  /// For example `juicer.decodeJson(json, (_) => Party())` will be
  /// used if a `Party` object is expected (provided the `Juicer` has
  /// a mapper for `Party`)
  dynamic decodeJson(String val, [AdaptingFactory targetFactory]) {
    return decode(json.decode(val), targetFactory);
  }

  /// Encodes [val] to a JSON compatible object: scalars to scalars,
  /// lists to lists, maps to maps, mappable classes to maps recursively
  dynamic encode(dynamic val) {
    if (val == null) return null;
    if (val is JuicerOverride) val = (val as JuicerOverride).writeReplace();
    ClassMapper mapper = mappers[val.runtimeType];
    if (mapper != null) return mapper.toMap(this, val);
    if (val is Map) {
      return Map.fromIterable(val.keys,
          key: (k) => k as String, value: (k) => encode(val[k]));
    }
    if (val is Iterable) return val.map((e) => encode(e)).toList();
    return val;
  }

  /// Decodes [val] to adapted to the object returned by [targetFactory].
  ///
  /// If [val] is an encoded version of class `A` the
  /// `juicer.decode(val, (_) => A())` will return an instance of `A` with
  /// all the fields recursively adapted.
  dynamic decode(dynamic val, [AdaptingFactory targetFactory]) {
    if (val == null) return null;
    if (val is Map) {
      if (targetFactory == null) {
        return decodeMap(val);
      } else {
        dynamic target = targetFactory(val);
        ClassMapper mapper = mappers[target.runtimeType];
        return mapper.fromMap(this, val, target);
      }
    } else if (val is Iterable) {
      return decodeIterable(val, targetFactory);
    } else if (targetFactory != null) {
      return targetFactory(val);
    } else {
      return val;
    }
  }

  /// Used to decode a Map-like value ([val]) where each of the values
  /// may be adapted (using [itemFactory]), and the resulting
  /// map will be [resultMap] (so it implicitly defines the exact type)
  Map decodeMap(dynamic val, [AdaptingFactory itemFactory, dynamic resultMap]) {
    if (val == null) return null;
    if (resultMap != null) {
      for (dynamic key in val.keys) {
        resultMap[key] = decode(val[key], itemFactory);
      }
      return resultMap;
    }
    return new Map<String, dynamic>.fromIterable(val.keys,
        value: (k) => decode(val[k], itemFactory));
  }

  /// Used to decode an Iterable value ([val]) where each of the elements
  /// may be adapted (using [itemFactory]), and the resulting
  /// collection will be [resultList] (so it implicitly defines the exact type)
  List decodeIterable(dynamic val,
      [AdaptingFactory itemFactory, dynamic resultList]) {
    if (val == null) return null;
    if (resultList != null) {
      for (dynamic item in val) {
        resultList.add(decode(item, itemFactory));
      }
      return resultList;
    }
    return val?.map((e) => decode(e, itemFactory))?.toList();
  }

  /// Removes all the `null` values from the map
  Map<K, V> removeNullValues<K, V>(Map<K, V> map) {
    map.removeWhere((key, value) => value == null);
    return map;
  }

  /// Returns the mapper for the given type or `null` if the type
  /// unknown to this juicer
  ClassMapper getMapper(Type type) => mappers[type];

  @override
  String toString() {
    String mapperList = mappers.keys.join(", ");
    return "Juicer($mapperList)";
  }

  /// The map of mappers in this juicer.
  final Map<Type, ClassMapper> mappers;
}
