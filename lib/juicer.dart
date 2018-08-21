
abstract class ClassMapper<T> {
  const ClassMapper();
  Map<String, dynamic> toMap(Juicer juicer, T val);
  T fromMap(Juicer juicer, Map<String, dynamic> map, T empty);
}

typedef T AdaptingFactory<T>(dynamic valueToAdapt);

class Juicer {
  const Juicer(this.mappers);

  Juicer combine(Juicer other) {
    Map<Type, ClassMapper> union = new Map.from(mappers);
    union.addAll(other.mappers);
    return new Juicer(new Map.unmodifiable(union));
  }

  dynamic encode(dynamic val) {
    if (val == null) return null;
    ClassMapper mapper = mappers[val.runtimeType];
    if (mapper != null) return mapper.toMap(this, val);
    return val;
  }

  dynamic decode(dynamic val, [AdaptingFactory targetFactory]) {
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

  Map decodeMap(dynamic val, [AdaptingFactory itemFactory, dynamic mapTemplate]) {
    if (val == null) return null;
    if (mapTemplate != null) {
      for (dynamic key in val.keys) {
        mapTemplate[key] = decode(val[key], itemFactory);
      }
      return mapTemplate;
    }
    return new Map.fromIterable(val.keys, value: (k) => decode(val[k], itemFactory));
  }

  List decodeIterable(dynamic val, [AdaptingFactory itemFactory, dynamic listTemplate]) {
    if (listTemplate != null) {
      for (dynamic item in val) {
        listTemplate.add(decode(item, itemFactory));
      }
      return listTemplate;
    }
    return val?.map((e) => decode(e, itemFactory))?.toList();
  }

  ClassMapper getMapper(Type type) => mappers[type];

  final Map<Type, ClassMapper> mappers;
}
