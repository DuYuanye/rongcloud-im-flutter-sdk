import '../../rongcloud_im_plugin.dart';
import 'dart:convert' show json;
import 'dart:developer' as developer;

class CommandMessage extends MessageContent {
  static const String objectName = "RC:CmdMsg";

  String? name;
  String? data;

  /// [name] 名称
  /// [data] 内容
  static CommandMessage obtain(String name, String data) {
    CommandMessage msg = new CommandMessage();
    msg.name = name;
    msg.data = data;
    return msg;
  }

  @override
  void decode(String? jsonStr) {
    if (jsonStr == null) {
      developer.log("Flutter CommandMessage deocde error: no name no data",
          name: "RongIMClient.CommandMessage");
      return;
    }
    Map map = json.decode(jsonStr.toString());
    this.name = map["name"];
    this.data = map["data"];
    Map? userMap = map["user"];
    super.decodeUserInfo(userMap);
  }

  @override
  String encode() {
    Map map = {"name": this.name, "data": this.data};
    if (this.sendUserInfo != null) {
      Map userMap = super.encodeUserInfo(this.sendUserInfo);
      map["user"] = userMap;
    }
    return json.encode(map);
  }

  @override
  String conversationDigest() {
    return "命令";
  }

  @override
  String getObjectName() {
    return objectName;
  }
}
