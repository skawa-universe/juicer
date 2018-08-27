class Juiced {
  const Juiced();
}

const Juiced juiced = const Juiced();

class Property {
  const Property({this.name, this.ignore});

  Property withName(String newName) => Property(name: newName, ignore: ignore);

  Property withIgnore(bool newIgnore) => Property(name: name, ignore: newIgnore);

  final String name;
  final bool ignore;
}

abstract class JuicerOverride {
  const JuicerOverride();

  dynamic writeReplace() => this;
}
