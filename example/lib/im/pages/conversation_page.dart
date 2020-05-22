import 'dart:io';

import 'package:flutter/material.dart';
import 'package:rongcloud_im_plugin/rongcloud_im_plugin.dart';
import 'package:rongcloud_im_plugin_example/im/util/combine_message_util.dart';
import 'item/bottom_tool_bar.dart';
import 'package:path/path.dart' as path;

import '../util/style.dart';
import 'item/bottom_input_bar.dart';
import 'item/message_content_list.dart';
import 'item/widget_util.dart';

import '../util/user_info_datesource.dart' as example;
import '../util/media_util.dart';
import '../util/event_bus.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import '../util/dialog_util.dart';

enum ConversationStatus {
  Normal, //正常
  VoiceRecorder, //语音输入，页面中间回弹出录音的 gif
}

class ConversationPage extends StatefulWidget {
  final Map arguments;
  ConversationPage({Key key, this.arguments}) : super(key: key);

  @override
  State<StatefulWidget> createState() =>
      _ConversationPageState(arguments: this.arguments);
}

class _ConversationPageState extends State<ConversationPage>
    implements
        BottomInputBarDelegate,
        MessageContentListDelegate,
        BottomToolBarDelegate {
  Map arguments;
  int conversationType;
  String targetId;

  List phrasesList = new List(); // 快捷回复，短语数组
  List messageDataSource = new List(); //消息数组
  List<Widget> extWidgetList = new List(); //加号扩展栏的 widget 列表
  ConversationStatus currentStatus; //当前输入工具栏的状态
  String textDraft = ''; //草稿内容
  BottomInputBar bottomInputBar;
  BottomToolBar bottomToolBar;
  String titleContent;
  InputBarStatus currentInputStatus;
  ListView phrasesListView;
  List emojiList = new List(); // emoji 数组

  MessageContentList messageContentList;
  example.BaseInfo info;

  bool multiSelect = false; //是否是多选模式
  List selectedMessageIds =
      new List(); //已经选择的所有消息Id，只有在 multiSelect 为 YES,才会有有效值
  List userIdList = new List();
  int recordTime = 0;
  Map burnMsgMap = Map();
  bool isSecretChat = false;
  bool isFirstGetHistoryMessages = true;

  _ConversationPageState({this.arguments});
  @override
  void initState() {
    super.initState();
    _requestPermissions();

    messageContentList = MessageContentList(
        messageDataSource, multiSelect, selectedMessageIds, this, burnMsgMap);
    conversationType = arguments["coversationType"];
    targetId = arguments["targetId"];
    currentStatus = ConversationStatus.Normal;
    bottomInputBar = BottomInputBar(this);
    bottomToolBar = BottomToolBar(this);

    setInfo();
    // if (conversationType == RCConversationType.Private) {
    //   setInfo(targetId);
    // } else {
    //   this.info = example.UserInfoDataSource.getGroupInfo(targetId);
    // }

    titleContent = '与 $targetId 的会话';

    //增加 IM 监听
    _addIMHandler();
    //获取默认的历史消息
    onGetHistoryMessages();
    //增加加号扩展栏的 widget
    _initExtentionWidgets();
    //获取草稿内容
    onGetTextMessageDraft();
  }

  void setInfo() {
    example.UserInfo userInfo =
        example.UserInfoDataSource.cachedUserMap[targetId];
    example.GroupInfo groupInfo =
        example.UserInfoDataSource.cachedGroupMap[targetId];
    if (conversationType == RCConversationType.Private) {
      if (userInfo != null) {
        this.info = userInfo;
      } else {
        example.UserInfoDataSource.getUserInfo(targetId).then((onValue) {
          setState(() {
            this.info = onValue;
          });
        });
      }
    } else {
      if (groupInfo != null) {
        this.info = groupInfo;
      } else {
        example.UserInfoDataSource.getGroupInfo(targetId).then((onValue) {
          setState(() {
            this.info = onValue;
          });
        });
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
    if (textDraft == null) {
      textDraft = '';
    }
    RongIMClient.saveTextMessageDraft(conversationType, targetId, textDraft);
    RongIMClient.clearMessagesUnreadStatus(conversationType, targetId);
    EventBus.instance.commit(EventKeys.ConversationPageDispose, null);
    EventBus.instance.removeListener(EventKeys.ReceiveMessage);
    EventBus.instance.removeListener(EventKeys.ReceiveReadReceipt);
    EventBus.instance.removeListener(EventKeys.ReceiveReceiptRequest);
    EventBus.instance.removeListener(EventKeys.ReceiveReceiptResponse);
    MediaUtil.instance.stopPlayAudio();
  }

  void _pullMoreHistoryMessage() async {
    //todo 加载更多历史消息

    int messageId = -1;
    Message tempMessage = messageDataSource.last;
    if (tempMessage != null && tempMessage.messageId > 0) {
      messageId = tempMessage.messageId;
      recordTime = tempMessage.sentTime;
    }
    onLoadMoreHistoryMessages(messageId);
  }

  ///请求相应的权限，只会在此一次触发
  void _requestPermissions() {
    MediaUtil.instance.requestPermissions();
  }

  _addIMHandler() {
    EventBus.instance.addListener(EventKeys.ReceiveMessage, (map) {
      Message msg = map["message"];
      // int left = map["left"];
      if (msg.targetId == this.targetId) {
        _insertOrReplaceMessage(msg);
      }
      _sendReadReceipt();
      // // 测试接收阅后即焚直接焚烧
      // RongIMClient.messageBeginDestruct(msg);
    });

    EventBus.instance.addListener(EventKeys.ReceiveReadReceipt, (map) {
      String tId = map["tId"];
      if (tId == this.targetId) {
        onGetHistoryMessages();
      }
    });

    EventBus.instance.addListener(EventKeys.ReceiveReceiptRequest, (map) {
      String tId = map["targetId"];
      String messageUId = map["messageUId"];
      if (tId == this.targetId) {
        _sendReadReceiptResponse(messageUId);
      }
    });

    EventBus.instance.addListener(EventKeys.ReceiveReceiptResponse, (map) {
      String tId = map["targetId"];
      print("ReceiveReceiptResponse" + tId + this.targetId);
      if (tId == this.targetId) {
        onGetHistoryMessages();
      }
    });

    EventBus.instance.addListener(EventKeys.ForwardMessageEnd, (arg) {
      print("ForwardMessageEnd：" + this.targetId);
      multiSelect = false;
      selectedMessageIds.clear();
      // onGetHistoryMessages();
      _refreshMessageContentListUI();
      _refreshUI();
    });

    RongIMClient.onMessageSend = (int messageId, int status, int code) async {
      print("messageId:$messageId status:$status code:$code");
      Message msg = await RongIMClient.getMessage(messageId);
      if (msg.targetId == this.targetId) {
        _insertOrReplaceMessage(msg);
      }
    };

    RongIMClient.onMessageDestructing =
        (Message message, int remainDuration) async {
      EventBus.instance.commit(EventKeys.BurnMessage,
          {"messageId": message.messageId, "remainDuration": remainDuration});
      print(message.toString() + remainDuration.toString());
      burnMsgMap[message.messageId] = remainDuration;
      if (remainDuration == 0) {
        onGetHistoryMessages();
        int index = -1;
        for (var i = 0; i < messageDataSource.length; i++) {
          Message msg = messageDataSource[i];
          if (msg.messageId == message.messageId) {
            index = i;
            break;
          }
        }
        messageDataSource.removeAt(index);
        burnMsgMap.remove(message.messageId);
        _refreshMessageContentListUI();
      }
    };

    RongIMClient.onTypingStatusChanged =
        (int conversationType, String targetId, List typingStatus) async {
      if (conversationType == this.conversationType &&
          targetId == this.targetId) {
        if (typingStatus.length > 0) {
          TypingStatus status = typingStatus[typingStatus.length - 1];
          if (status.typingContentType == TextMessage.objectName) {
            titleContent = RCString.ConTyping;
          } else if (status.typingContentType == VoiceMessage.objectName ||
              status.typingContentType == 'RC:VcMsg') {
            titleContent = RCString.ConSpeaking;
          }
        } else {
          titleContent = '与 $targetId 的会话';
        }
        _refreshUI();
      }
    };

    RongIMClient.onRecallMessageReceived = (Message message) async {
      if (message != null) {
        if (message.targetId == this.targetId) {
          _insertOrReplaceMessage(message);
        }
      }
    };

    RongIMClient.onDownloadMediaMessageResponse =
        (int code, int progress, int messageId, Message message) async {
      // 下载媒体消息后更新对应的消息
      if (code == 0) {
        _replaceMeidaMessage(message);
      }
    };
  }

  onGetHistoryMessages() async {
    print("get history message");

    List msgs =
        await RongIMClient.getHistoryMessage(conversationType, targetId, 0, 20);
    if (msgs != null) {
      msgs.sort((a, b) => b.sentTime.compareTo(a.sentTime));
      messageDataSource = msgs;
    }
    if (isFirstGetHistoryMessages) {
      _sendReadReceipt();
    }
    _refreshMessageContentListUI();
    isFirstGetHistoryMessages = false;
  }

  onLoadMoreHistoryMessages(int messageId) async {
    print("get more history message");

    List msgs = await RongIMClient.getHistoryMessage(
        conversationType, targetId, messageId, 20);
    if (msgs != null) {
      msgs.sort((a, b) => b.sentTime.compareTo(a.sentTime));
      messageDataSource += msgs;
      if (msgs.length < 20) {
        Message tempMessage = messageDataSource.last;
        recordTime = tempMessage.sentTime;
        onLoadRemoteHistoryMessages();
      }
    }
    _refreshMessageContentListUI();
  }

  onLoadRemoteHistoryMessages() async {
    print("get Remote history message");

    RongIMClient.getRemoteHistoryMessages(
        conversationType, targetId, recordTime, 20,
        (List/*<Message>*/ msgList, int code) {
      if (code == 0 && msgList != null) {
        msgList.sort((a, b) => b.sentTime.compareTo(a.sentTime));
        messageDataSource += msgList;
        if (msgList.length == 20) {
          _refreshMessageContentListUI();
        }
      }
    });
  }

  onGetTextMessageDraft() async {
    textDraft =
        await RongIMClient.getTextMessageDraft(conversationType, targetId);
    if (bottomInputBar != null) {
      bottomInputBar.setTextContent(textDraft);
    }
    // _refreshUI();
  }

  void _replaceMeidaMessage(Message message) {
    for (int i = 0; i < messageDataSource.length; i++) {
      Message msg = messageDataSource[i];
      if (msg.messageId == message.messageId) {
        MessageContent messageContent = msg.content;
        if (messageContent is ImageMessage ||
            messageContent is SightMessage ||
            messageContent is GifMessage) {
          messageDataSource[i] = message;
        }
      }
      break;
    }
  }

  void _insertOrReplaceMessage(Message message) {
    int index = -1;
    for (int i = 0; i < messageDataSource.length; i++) {
      Message msg = messageDataSource[i];
      if (msg.messageId == message.messageId) {
        index = i;
        break;
      }
    }
    //如果数据源中相同 id 消息，那么更新对应消息，否则插入消息
    if (index >= 0) {
      messageDataSource[index] = message;
      messageContentList.refreshItem(message);
    } else {
      messageDataSource.insert(0, message);
      _refreshMessageContentListUI();
    }
  }

  Widget _getExtentionWidget() {
    if (currentInputStatus == InputBarStatus.Extention) {
      return Container(
          height: RCLayout.ExtentionLayoutWidth,
          child: GridView.count(
            physics: new NeverScrollableScrollPhysics(),
            crossAxisCount: 4,
            padding: EdgeInsets.all(10),
            children: extWidgetList,
          ));
    } else if (currentInputStatus == InputBarStatus.Phrases) {
      return Container(
          height: RCLayout.ExtentionLayoutWidth, child: _buildPhrasesList());
    } else if (currentInputStatus == InputBarStatus.Emoji) {
      return Container(
          height: RCLayout.ExtentionLayoutWidth, child: _buildEmojiList());
    } else {
      if (currentInputStatus == InputBarStatus.Voice) {
        bottomInputBar.refreshUI();
      }
      return WidgetUtil.buildEmptyWidget();
    }
  }

  GridView _buildEmojiList() {
    return GridView(
      scrollDirection: Axis.vertical,
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: MediaQuery.of(context).size.width / 8,
      ),
      children: List.generate(
        emojiList.length,
        (index) {
          return GestureDetector(
            onTap: () {
              bottomInputBar.setTextContent(emojiList[index]);
            },
            child: Center(
              widthFactor: MediaQuery.of(context).size.width / 8,
              heightFactor: MediaQuery.of(context).size.width / 8,
              child: Text(emojiList[index], style: TextStyle(fontSize: 25)),
            ),
          );
        },
      ),
    );
  }

  ListView _buildPhrasesList() {
    if (phrasesListView != null) {
      return phrasesListView;
    }
    return ListView.separated(
        key: UniqueKey(),
        controller: ScrollController(),
        itemCount: phrasesList.length,
        itemBuilder: (BuildContext context, int index) {
          if (phrasesList.length != null && phrasesList.length > 0) {
            String contentStr = phrasesList[index];
            return GestureDetector(
                onTap: () {
                  _clickPhrases(contentStr);
                },
                child: Container(
                  alignment: Alignment.center,
                  child: Text(contentStr,
                      style: new TextStyle(
                        fontSize: RCFont.CommonPhrasesSize,
                      )),
                  height: RCLayout.CommonPhrasesHeight,
                ));
          } else {
            return WidgetUtil.buildEmptyWidget();
          }
        },
        separatorBuilder: (BuildContext context, int index) {
          return Container(
            color: Color(0xffC8C8C8),
            height: 0.5,
          );
        });
  }

  void _clickPhrases(String contentStr) async {
    currentInputStatus = InputBarStatus.Normal;
    TextMessage msg = new TextMessage();
    msg.content = contentStr;
    if (conversationType == RCConversationType.Private) {
      int duration = contentStr.length <= 20
          ? RCDuration.TextMessageBurnDuration
          : (RCDuration.TextMessageBurnDuration + (contentStr.length - 20) / 2);
      msg.destructDuration = isSecretChat ? duration : 0;
    }

    Message message =
        await RongIMClient.sendMessage(conversationType, targetId, msg);
    // 统一转成了 onMessageSend 回调处理
    // _insertOrReplaceMessage(message);
  }

  void _deleteMessage(Message message) {
    //删除消息完成需要刷新消息数据源
    RongIMClient.deleteMessageByIds([message.messageId], (int code) {
      onGetHistoryMessages();
    });
    // 远程删除测试入口
    // List<Message> messageList = List();
    // messageList.add(message);
    // RongIMClient.deleteRemoteMessages(conversationType, targetId, messageList, (code){
    //   print("result: $code");
    //   onGetHistoryMessages();
    // });
  }

  void _recallMessage(Message message) async {
    RecallNotificationMessage recallNotifiMessage =
        await RongIMClient.recallMessage(message, "");
    if (recallNotifiMessage != null) {
      message.content = recallNotifiMessage;
      _insertOrReplaceMessage(message);
    } else {
      showShortToast("撤回失败");
    }
  }

  void showShortToast(String message) {
    Fluttertoast.showToast(
        msg: message, toastLength: Toast.LENGTH_SHORT, timeInSecForIos: 1);
  }

  /// 禁止随意调用 setState 接口刷新 UI，必须调用该接口刷新 UI
  void _refreshUI() {
    setState(() {});
  }

  void _refreshMessageContentListUI() {
    messageContentList.updateData(
        messageDataSource, multiSelect, selectedMessageIds);
  }

  void _initExtentionWidgets() {
    Widget imageWidget = WidgetUtil.buildExtentionWidget(
        Icons.photo, RCString.ExtPhoto, () async {
      String imgPath = await MediaUtil.instance.pickImage();
      if (imgPath == null) {
        return;
      }
      print("imagepath " + imgPath);
      if (imgPath.endsWith("gif")) {
        GifMessage gifMsg = GifMessage.obtain(imgPath);
        if (conversationType == RCConversationType.Private) {
          gifMsg.destructDuration =
              isSecretChat ? RCDuration.MediaMessageBurnDuration : 0;
        }
        Message msg =
            await RongIMClient.sendMessage(conversationType, targetId, gifMsg);
        _insertOrReplaceMessage(msg);
      } else {
        ImageMessage imgMsg = ImageMessage.obtain(imgPath);
        if (conversationType == RCConversationType.Private) {
          imgMsg.destructDuration =
              isSecretChat ? RCDuration.MediaMessageBurnDuration : 0;
        }
        // UserInfo sendUserInfo = new UserInfo();
        // sendUserInfo.name = "textSendUser.name";
        // sendUserInfo.userId = "textSendUser.userId";
        // sendUserInfo.portraitUri = "textSendUser.portraitUrl";
        // sendUserInfo.extra = "textSendUser.extra";
        // imgMsg.sendUserInfo = sendUserInfo;
        // // ImageMessage 携带 @ 信息
        // MentionedInfo mentionedInfo = new MentionedInfo();
        // mentionedInfo.type = 2;
        // mentionedInfo.userIdList = ["kj","oi","op"];
        // mentionedInfo.mentionedContent = "pppppppp";
        // imgMsg.mentionedInfo = mentionedInfo;
        // // ImageMessage 测试阅后即焚携带时间
        // imgMsg.destructDuration = 10;
        Message msg =
            await RongIMClient.sendMessage(conversationType, targetId, imgMsg);
        _insertOrReplaceMessage(msg);
      }
    });

    Widget cameraWidget = WidgetUtil.buildExtentionWidget(
        Icons.camera, RCString.ExtCamera, () async {
      String imgPath = await MediaUtil.instance.takePhoto();
      if (imgPath == null) {
        return;
      }
      print("imagepath " + imgPath);
      String temp = imgPath.replaceAll("file://", "");
      // 保存不需要 file 开头的路径
      _saveImage(temp);
      ImageMessage imgMsg = ImageMessage.obtain(imgPath);
      if (conversationType == RCConversationType.Private) {
        imgMsg.destructDuration =
            isSecretChat ? RCDuration.MediaMessageBurnDuration : 0;
      }
      Message msg =
          await RongIMClient.sendMessage(conversationType, targetId, imgMsg);
      _insertOrReplaceMessage(msg);
    });

    Widget videoWidget = WidgetUtil.buildExtentionWidget(
        Icons.video_call, RCString.ExtVideo, () async {
      print("push to video record page");
      Map map = {
        "coversationType": conversationType,
        "targetId": targetId,
        "isSecretChat": isSecretChat
      };
      Navigator.pushNamed(context, "/video_record", arguments: map);
    });

    Widget fileWidget = WidgetUtil.buildExtentionWidget(
        Icons.folder, RCString.ExtFolder, () async {
      List<File> files = await MediaUtil.instance.pickFiles();
      if (files != null && files.length > 0) {
        for (File file in files) {
          String localPaht = file.path;
          String name = path.basename(localPaht);
          int lastDotIndex = name.lastIndexOf(".");
          FileMessage fileMessage = FileMessage.obtain(localPaht);
          fileMessage.mType = name.substring(lastDotIndex + 1);
          Message msg = await RongIMClient.sendMessage(
              conversationType, targetId, fileMessage);
          _insertOrReplaceMessage(msg);
          // 延迟400秒，防止过渡频繁的发送消息导致发送失败的问题
          sleep(Duration(milliseconds: 400));
        }
      }
    });

    extWidgetList.add(imageWidget);
    extWidgetList.add(cameraWidget);
    extWidgetList.add(videoWidget);
    extWidgetList.add(fileWidget);
    if (conversationType == RCConversationType.Private) {
      Widget secretChatWidget = WidgetUtil.buildExtentionWidget(
        Icons.security, RCString.ExtSecretChat, () async {
      print("did tap secret chat");
      isSecretChat = !isSecretChat;
      String contentStr = isSecretChat ? "打开阅后即焚" : "关闭阅后即焚";
      print(contentStr);
      DialogUtil.showAlertDiaLog(context, contentStr);
    });
      extWidgetList.add(secretChatWidget);
    }

    //初始化短语
    for (int i = 0; i < 10; i++) {
      phrasesList.add('快捷回复测试用例 $i');
    }

    emojiList = Emoji.emojiList;
  }

  void _saveImage(String imagePath) async {
    final result = await ImageGallerySaver.saveFile(imagePath);
    print("save image result: " + result.toString());
  }

  void _sendReadReceipt() {
    if (conversationType == RCConversationType.Private) {
      for (int i = 0; i < messageDataSource.length; i++) {
        Message message = messageDataSource[i];
        if (message.messageDirection == RCMessageDirection.Receive) {
          RongIMClient.sendReadReceiptMessage(
              this.conversationType, this.targetId, message.sentTime,
              (int code) {
            if (code == 0) {
              print('sendReadReceiptMessageSuccess');
            } else {
              print('sendReadReceiptMessageFailed:code = + $code');
            }
          });
          RongIMClient.syncConversationReadStatus(
            this.conversationType, this.targetId, message.sentTime, (int code) {
          if (code == 0) {
            print('syncConversationReadStatusSuccess');
          } else {
            print('syncConversationReadStatusFailed:code = + $code');
          }
        });
          break;
        }
      }
    } else if (conversationType == RCConversationType.Group) {
      _sendReadReceiptResponse(null);
    }
    // _syncReadStatus();
  }

  // void _syncReadStatus() {
  //   for (int i = 0; i < messageDataSource.length; i++) {
  //     Message message = messageDataSource[i];
  //     if (message.messageDirection == RCMessageDirection.Receive) {
  //       RongIMClient.syncConversationReadStatus(
  //           this.conversationType, this.targetId, message.sentTime, (int code) {
  //         if (code == 0) {
  //           print('syncConversationReadStatusSuccess');
  //         } else {
  //           print('syncConversationReadStatusFailed:code = + $code');
  //         }
  //       });
  //       break;
  //     }
  //   }
  // }

  ///长按录制语音的 gif 动画
  Widget _buildExtraCenterWidget() {
    if (this.currentStatus == ConversationStatus.VoiceRecorder) {
      return WidgetUtil.buildVoiceRecorderWidget();
    } else {
      return WidgetUtil.buildEmptyWidget();
    }
  }

  void _showExtraCenterWidget(ConversationStatus status) {
    this.currentStatus = status;
    _refreshUI();
  }

  // 底部输入栏
  Widget _buildBottomInputBar() {
    if (multiSelect == true) {
      return bottomToolBar;
    } else {
      return bottomInputBar;
    }
  }

  void _pushToDebug() {
    Map arg = {"coversationType": conversationType, "targetId": targetId};
    Navigator.pushNamed(context, "/chat_debug", arguments: arg);
  }

  // AppBar 右侧按钮
  List _buildRightButtons() {
    if (multiSelect == true) {
      return <Widget>[
        FlatButton(
          child: Text(RCString.ConCancel),
          textColor: Colors.white,
          onPressed: () {
            multiSelect = false;
            selectedMessageIds.clear();
            _refreshMessageContentListUI();
            _refreshUI();
          },
        )
      ];
    } else {
      return <Widget>[
        IconButton(
          icon: Icon(Icons.more),
          onPressed: () {
            _pushToDebug();
          },
        ),
      ];
    }
  }

  void _sendReadReceiptResponse(String messageUId) {
    List readReceiptList = List();
    for (Message message in this.messageDataSource) {
      if ((messageUId != null && message.messageUId == messageUId) ||
          (message.readReceiptInfo != null &&
              message.readReceiptInfo.isReceiptRequestMessage &&
              !message.readReceiptInfo.hasRespond &&
              message.messageDirection == RCMessageDirection.Receive)) {
        readReceiptList.add(message);
      }
    }
    if (readReceiptList.length > 0) {
      RongIMClient.sendReadReceiptResponse(
          this.conversationType, this.targetId, readReceiptList, (int code) {
        if (code == 0) {
          print('sendReadReceiptResponseSuccess');
        } else {
          print('sendReadReceiptResponseFailed:code = + $code');
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: Text(titleContent),
          actions: _buildRightButtons(),
        ),
        body: Container(
          child: Stack(
            children: <Widget>[
              SafeArea(
                child: Column(
                  children: <Widget>[
                    Flexible(
                      child: Column(
                        children: <Widget>[Flexible(child: messageContentList)],
                      ),
                    ),
                    Container(
                      height: multiSelect ? 55 : 82,
                      child: _buildBottomInputBar(),
                    ),
                    _getExtentionWidget(),
                  ],
                ),
              ),
              _buildExtraCenterWidget(),
            ],
          ),
        ));
  }

  @override
  void didTapMessageItem(Message message) async {
    print("didTapMessageItem " + message.objectName);
    // RongIMClient.setMessageReceivedStatus(message.messageId, 1, (code) async{
    //   print("setMessageReceivedStatus result:$code");
    //   Message msg = await RongIMClient.getMessage(message.messageId);
    //   print("getMessage result:${msg.toString()}");
    // });
    // List<int> conversations = List();
    // conversations.add(3);
    // RongIMClient.clearConversations(conversations, (code) async{
    //   print("clearConversations result:$code");
    // });
    // print("getDeltaTime result:${await RongIMClient.getDeltaTime()}");
    // RongIMClient.setOfflineMessageDuration(3, (code, result){
    //   print("setOfflineMessageDuration code:$code result:$result");
    // });
    // print("getOfflineMessageDuration code:${await RongIMClient.getOfflineMessageDuration()}");
    // print('getConnectionStatus: ${await RongIMClient.getConnectionStatus()}');
    // RongIMClient.setReconnectKickEnable(true);
    if (message.messageDirection == RCMessageDirection.Receive &&
        message.content.destructDuration != null &&
        message.content.destructDuration > 0 && multiSelect != true)
      RongIMClient.messageBeginDestruct(message);
    if (message.content is VoiceMessage) {
      VoiceMessage msg = message.content;
      if (msg.localPath != null &&
          msg.localPath.isNotEmpty &&
          File(msg.localPath).existsSync()) {
        MediaUtil.instance.startPlayAudio(msg.localPath);
      } else {
        MediaUtil.instance.startPlayAudio(msg.remoteUrl);
        RongIMClient.downloadMediaMessage(message);
      }
    } else if (message.content is ImageMessage ||
        message.content is GifMessage) {
      Navigator.pushNamed(context, "/image_preview", arguments: message);
    } else if (message.content is SightMessage) {
      Navigator.pushNamed(context, "/video_play", arguments: message);
    } else if (message.content is FileMessage) {
      Navigator.pushNamed(context, "/file_preview", arguments: message);
    } else if (message.content is RichContentMessage) {
      RichContentMessage msg = message.content;
      Map param = {"url": msg.url, "title": msg.title};
      Navigator.pushNamed(context, "/webview", arguments: param);
    } else if (message.content is CombineMessage) {
      CombineMessage msg = message.content;
      String localPath = msg.localPath;
      String mediaUrl = msg.mMediaUrl;
      String url = "";
      if (localPath != null && localPath.isNotEmpty) {
        url = localPath;
      } else if (mediaUrl != null && mediaUrl.isNotEmpty) {
        localPath = await CombineMessageUtils().getLocalPathFormUrl(mediaUrl);
        if (File(localPath).existsSync()) {
          url = localPath;
        } else {
          url = mediaUrl;
        }
      }
      Map param = {"url": url, "title": CombineMessageUtils().getTitle(msg)};
      Navigator.pushNamed(context, "/webview", arguments: param);
    }
  }

  @override
  void didSendMessageRequest(Message message) {
    print("didSendMessageRequest " + message.objectName);
    RongIMClient.sendReadReceiptRequest(message, (int code) {
      if (0 == code) {
        print("sendReadReceiptRequest success");
        onGetHistoryMessages();
      } else {
        print("sendReadReceiptRequest error");
      }
    });
  }

  @override
  void didTapMessageReadInfo(Message message) {
    print("didTapMessageReadInfo " + message.objectName);
    Navigator.pushNamed(context, "/message_read_page", arguments: message);
  }

  @override
  void didLongPressMessageItem(Message message, Offset tapPos) {
    Map<String, String> actionMap = {
      RCLongPressAction.DeleteKey: RCLongPressAction.DeleteValue,
      RCLongPressAction.MutiSelectKey: RCLongPressAction.MutiSelectValue
    };
    if (message.messageDirection == RCMessageDirection.Send) {
      actionMap[RCLongPressAction.RecallKey] = RCLongPressAction.RecallValue;
    }
    WidgetUtil.showLongPressMenu(context, tapPos, actionMap, (String key) {
      if (key == RCLongPressAction.DeleteKey) {
        _deleteMessage(message);
      } else if (key == RCLongPressAction.RecallKey) {
        _recallMessage(message);
      } else if (key == RCLongPressAction.MutiSelectKey) {
        this.multiSelect = true;
        currentInputStatus = InputBarStatus.Normal;
        _refreshMessageContentListUI();
        _refreshUI();
      }
      print("当前选中的是 " + key);
    });
  }

  @override
  void didTapUserPortrait(String userId) {
    print("点击了用户头像 " + userId);
  }

  @override
  void didTapItem(Message message) {
    if (multiSelect) {
      final alreadySaved = selectedMessageIds.contains(message.messageId);
      if (alreadySaved) {
        selectedMessageIds.remove(message.messageId);
      } else {
        selectedMessageIds.add(message.messageId);
      }
    }
  }

  @override
  void didLongPressUserPortrait(String userId, Offset tapPos) {
    if (conversationType == RCConversationType.Group) {
      String content = "@" + userId + " ";
      bottomInputBar.setTextContent(content);
      userIdList.add(userId);
    }
    print("长按头像");
  }

  @override
  void willSendText(String text) async {
    TextMessage msg = new TextMessage();
    msg.content = text;

    if (conversationType == RCConversationType.Group) {
      // 群组发送消息携带@信息
      List<String> tapUserIdList = List();
      for (String userId in this.userIdList) {
        if (text.contains(userId) && (!tapUserIdList.contains(userId))) {
          tapUserIdList.add(userId);
        }
      }
      if (tapUserIdList.length > 0) {
        MentionedInfo mentionedInfo = new MentionedInfo();
        mentionedInfo.type = RCMentionedType.Users;
        mentionedInfo.userIdList = tapUserIdList;
        mentionedInfo.mentionedContent = "这是 mentionedContent";
        msg.mentionedInfo = mentionedInfo;
      }
    }

    if (conversationType == RCConversationType.Private) {
      int duration = RCDuration.TextMessageBurnDuration;
      if (text.length > 20) {
        int textLength = text.length - 20;
        int tempDuration = (textLength / 2).ceil();
        duration += tempDuration;
      }
      msg.destructDuration = isSecretChat ? duration : 0;
    }

    Message message =
        await RongIMClient.sendMessage(conversationType, targetId, msg);
    userIdList.clear();
    _insertOrReplaceMessage(message);
  }

  @override
  void willSendVoice(String path, int duration) async {
    VoiceMessage msg = VoiceMessage.obtain(path, duration);
    if (conversationType == RCConversationType.Private) {
      msg.destructDuration =
          isSecretChat ? RCDuration.TextMessageBurnDuration + duration : 0;
    }
    Message message =
        await RongIMClient.sendMessage(conversationType, targetId, msg);
    _insertOrReplaceMessage(message);
  }

  @override
  void didTapExtentionButton() {}

  @override
  void inputStatusDidChange(InputBarStatus status) {
    currentInputStatus = status;
    bottomInputBar.refreshUI();
    _refreshUI();
  }

  @override
  void onTextChange(String text) {
    // print('input ' + text);
    textDraft = text;
    RongIMClient.sendTypingStatus(
        conversationType, targetId, TextMessage.objectName);
  }

  @override
  void willStartRecordVoice() {
    _showExtraCenterWidget(ConversationStatus.VoiceRecorder);
    RongIMClient.sendTypingStatus(conversationType, targetId, 'RC:VcMsg');
  }

  @override
  void willStopRecordVoice() {
    _showExtraCenterWidget(ConversationStatus.Normal);
  }

  @override
  void didTapDelete() {
    List<int> messageIds = new List<int>.from(selectedMessageIds);
    multiSelect = false;
    RongIMClient.deleteMessageByIds(messageIds, (int code) {
      if (code == 0) {
        onGetHistoryMessages();
        _refreshUI();
      }
    });
  }

  @override
  void didTapForward() async {
    List selectMsgs = new List();
    bool isAllowCombine = true;
    for (int msgId in selectedMessageIds) {
      Message forwardMsg = await RongIMClient.getMessage(msgId);
      if (!CombineMessageUtils.allowForward(forwardMsg.objectName)) {
        isAllowCombine = false;
      }
      if (forwardMsg.content == null || (forwardMsg.content != null && forwardMsg.content.destructDuration != null && forwardMsg.content.destructDuration > 0) || forwardMsg.sentStatus != RCSentStatus.Sent) {
        DialogUtil.showAlertDiaLog(context, "无法识别的消息、阅后即焚消息以及未发送成功的消息不支持转发");
        return;
      }
      selectMsgs.add(forwardMsg);
    }

    Map arguments = {"selectMessages": selectMsgs};
    DialogUtil.showBottomSheetDialog(context, {
      "逐条转发": () {
        arguments["forwardType"] = 0;
        Navigator.pushNamed(context, "/select_conversation_page",
            arguments: arguments);
      },
      "合并转发": () {
        if (isAllowCombine) {
          arguments["forwardType"] = 1;
          Navigator.pushNamed(context, "/select_conversation_page",
              arguments: arguments);
        } else {
          DialogUtil.showAlertDiaLog(context, RCString.ForwardHint);
        }
      },
      "取消": () {}
    });
  }

  @override
  void willpullMoreHistoryMessage() {
    _pullMoreHistoryMessage();
  }

  @override
  void didTapReSendMessage(Message message) async {
    RongIMClient.deleteMessageByIds([message.messageId], (int code) async {
      // 清除数据
      for (int i = 0; i < messageDataSource.length; i++) {
        Message msg = messageDataSource[i];
        if (msg.messageId == message.messageId) {
          messageDataSource.removeAt(i);
          break;
        }
      }
      Message msg = await RongIMClient.sendMessage(
          conversationType, targetId, message.content);
      _insertOrReplaceMessage(msg);
    });
  }
}
