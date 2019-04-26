# juicer

Lightweight JSON serialization library for plain, mutable classes.

Used as a `dartson` replacement.

## Example

```dart
import "dart:convert";
import "package:juicer/juicer_vm.dart";
import "package:juicer/metadata.dart";

@juiced
class Party {
  String key;
  String name;
  String country;
  String city;
  @Property(name: "street_address")
  String streetAddress;
  String zip;

  @Property(ignore: true)
  String get address => "$name\n$streetAddress\n$city\n$country";
}

void main() {
  Juicer juicer = juiceClasses([Party]);
  Map asMap = juicer.encode(new Party()
    ..key = "company_1234556"
    ..name = "Random Ltd."
    ..country = "Sovereignland"
    ..city = "Capitalcity"
    ..streetAddress = "1 Main Street"
    ..zip = "11111");
  // the map is encodable to JSON (you can also use encodeJson/decodeJson)
  print(json.encode(asMap));
  // create a copy by decoding the map
  Part copy = juicer.decode(asMap, (_) => Party());
  print(copy.address);
}
```

## Usage

A `Juicer` object “knows” how to encode or decode some classes into maps, and
handles all the JSON primitives as well. There are two modes of operation:

- using the build system it will generate the class-specific encoding code, and
will generate a `Juicer juicer` variable for those
- using mirrors it can create `Juicer` objects on the fly

In both cases all classes must be marked with the `@juiced` annotation
(from `metadata.dart`), the mirrors implementation (`juicer_vm.dart`) will map
non-juiced classes as well in some cases.

### Mirrors based implementation

The mirrors implementation provides the following functions:

- `createJuicerForLibraries`: juices all the libraries, or a filter can be provided
  which will filter based on the package URI
- `juiceLibraries`: juices the libraries with a specific name (for example you have a
  `comm` library with all these classes you can call `juiceLibraries(["comm"])` to get
  a juicer for all these)
- `juiceClasses`: juices a list of classes, the default behavior is to juice all classes
  and the referenced classes regardless of whether they have `@juiced` annotation

### Code generator based implementation

For every dart file that exports other dart files containing `@juiced` classes a `.pb.dart`
file will be generated.
