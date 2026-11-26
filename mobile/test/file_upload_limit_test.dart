import 'package:balance_app/data/services/file_upload_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 官方 Files API 限制：图片 64 MiB，PDF/Word/PPT 等 100 MiB，
/// 纯文本/表格/电子书 32 MiB。旧实现把所有 user_data 都卡在 32 MiB。
void main() {
  test('图片上限 64 MiB 且走 user_data 视觉通道', () {
    expect(
      FileUploadService.maxBytesFor('photo.jpg'),
      64 * 1024 * 1024,
    );
    expect(FileUploadService.purposeFor('photo.jpg'), 'user_data');
    expect(FileUploadService.isImage('photo.png'), isTrue);
  });

  test('需解析文档 100 MiB，纯文本 32 MiB', () {
    expect(FileUploadService.maxBytesFor('report.pdf'), 100 * 1024 * 1024);
    expect(FileUploadService.purposeFor('report.pdf'), 'rich_layout_recognition');
    expect(FileUploadService.maxBytesFor('notes.md'), 32 * 1024 * 1024);
    expect(FileUploadService.purposeFor('notes.md'), 'user_data');
  });

  test('不支持的格式不返回上限之外的行为', () {
    expect(FileUploadService.purposeFor('archive.zip'), '');
  });
}
