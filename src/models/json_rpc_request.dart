class JsonRpcRequest {
  final String jsonrpc;
  final String method;
  final dynamic params;
  final dynamic id;

  JsonRpcRequest({
    required this.jsonrpc,
    required this.method,
    this.params,
    this.id,
  });

  factory JsonRpcRequest.fromJson(Map<String, dynamic> json) {
    return JsonRpcRequest(
      jsonrpc: json['jsonrpc'],
      method: json['method'],
      params: json['params'],
      id: json['id'],
    );
  }
}

class JsonRpcResponse {
  final String jsonrpc;
  final dynamic result;
  final dynamic error;
  final dynamic id;

  JsonRpcResponse({
    this.jsonrpc = '2.0',
    this.result,
    this.error,
    required this.id,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{'jsonrpc': jsonrpc, 'id': id};

    if (error != null) {
      map['error'] = error;
    } else {
      map['result'] = result;
    }

    return map;
  }
}
