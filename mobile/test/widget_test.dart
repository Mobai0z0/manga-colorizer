import 'package:flutter_test/flutter_test.dart';

import 'package:manga_colorizer_mobile/main.dart';

void main() {
  testWidgets('工作台首屏渲染标题与空态引导', (tester) async {
    await tester.pumpWidget(const MangaColorizerApp());
    await tester.pumpAndSettle();

    expect(find.text('Manga Colorizer'), findsOneWidget);
    expect(find.textContaining('从相册选图'), findsAtLeastNWidgets(1));
  });
}
