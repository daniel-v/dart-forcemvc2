part of dart_force_mvc_lib;

class RequestMapping {
  
  final String value;
  final String method;
  const RequestMapping(this.value, this.method);

  String toString() => "$value -> $method";
  
}