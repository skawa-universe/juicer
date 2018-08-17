
abstract class ClassMapper<T> {
  const ClassMapper();
  Map<String, dynamic> toMap(Juicer juicer, T val);
  T fromMap(Juicer juicer, Map<String, dynamic> map, T empty);
}

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

  dynamic decode(dynamic val, [dynamic targetFactory(dynamic valToAdapt)]) {
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

  Map decodeMap(dynamic val, [dynamic itemFactory(dynamic valToAdapt)]) {
    if (val == null) return null;
    return new Map.fromIterable(val.keys, value: (k) => decode(val[k], itemFactory));
  }

  List decodeIterable(dynamic val, [dynamic itemFactory(dynamic valToAdapt)]) {
    return val?.map((e) => decode(e, itemFactory))?.toList();
  }

  final Map<Type, ClassMapper> mappers;
}
