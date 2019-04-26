import "dart:convert";

import "package:juicer/metadata.dart";

abstract class ClassMapper<T> {
  const ClassMapper();
  Map<String, dynamic> toMap(Juicer juicer, T val);
  T fromMap(Juicer juicer, Map map, T empty);
  T newInstance();
}

typedef T AdaptingFactory<T>(dynamic valueToAdapt);

class Juicer {
  const Juicer(this.mappers);

  Juicer combine(Juicer other) {
    Map<Type, ClassMapper> union = new Map.from(mappers);
    union.addAll(other.mappers);
    return new Juicer(new Map.unmodifiable(union));
  }

  String encodeJson(dynamic val) {
    return json.encode(encode(val));
  }

  dynamic decodeJson(String val, [AdaptingFactory targetFactory]) {
    return decode(json.decode(val), targetFactory);
  }

  dynamic encode(dynamic val) {
    if (val == null) return null;
    if (val is JuicerOverride) val = (val as JuicerOverride).writeReplace();
    ClassMapper mapper = mappers[val.runtimeType];
    if (mapper != null) return mapper.toMap(this, val);
    if (val is Map)
      return Map.fromIterable(val.keys,
          key: (k) => k as String, value: (k) => encode(val[k]));
    if (val is Iterable) return val.map((e) => encode(e)).toList();
    return val;
  }

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

  Map decodeMap(dynamic val,
      [AdaptingFactory itemFactory, dynamic mapTemplate]) {
    if (val == null) return null;
    if (mapTemplate != null) {
      for (dynamic key in val.keys) {
        mapTemplate[key] = decode(val[key], itemFactory);
      }
      return mapTemplate;
    }
    return new Map<String, dynamic>.fromIterable(val.keys,
        value: (k) => decode(val[k], itemFactory));
  }

  List decodeIterable(dynamic val,
      [AdaptingFactory itemFactory, dynamic listTemplate]) {
    if (val == null) return null;
    if (listTemplate != null) {
      for (dynamic item in val) {
        listTemplate.add(decode(item, itemFactory));
      }
      return listTemplate;
    }
    return val?.map((e) => decode(e, itemFactory))?.toList();
  }

  Map<K, V> removeNullValues<K, V>(Map<K, V> map) {
    map.removeWhere((key, value) => value == null);
    return map;
  }

  ClassMapper getMapper(Type type) => mappers[type];

  @override
  String toString() {
    String mapperList = mappers.keys.join(", ");
    return "Juicer($mapperList)";
  }

  final Map<Type, ClassMapper> mappers;
}
