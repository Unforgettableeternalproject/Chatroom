import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_app/widgets/attachment_view.dart';

void main() {
  test('伺服器網址結尾有斜線時不組出雙斜線', () {
    expect(attachmentUrl('http://h:8787/', 'abc'),
        'http://h:8787/api/attachments/abc');
    expect(attachmentUrl('http://h:8787', 'abc'),
        'http://h:8787/api/attachments/abc');
  });
}
