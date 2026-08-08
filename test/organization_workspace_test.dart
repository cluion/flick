import 'dart:io';

import 'package:flick/domain/organization_workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'reconciles paths without changing stable item identity or placement',
    () {
      var sequence = 0;
      String nextId() => 'item-${sequence++}';
      var draft = const OrganizationWorkspaceDraft().reconcilePaths(const [
        '/tmp/one.txt',
        '/tmp/two.txt',
      ], nextItemId: nextId);
      draft = draft.addFolder(
        const VirtualOrganizationFolder(id: 'photos', name: '圖片'),
      );
      draft = draft.assignItem(draft.items.first.id, 'photos');
      final firstId = draft.items.first.id;
      final secondId = draft.items.last.id;

      final reconciled = draft.reconcilePaths(const [
        '/tmp/two.txt',
        '/tmp/one.txt',
        '/tmp/three.txt',
      ], nextItemId: nextId);

      expect(reconciled.items.map((item) => item.id), [
        secondId,
        firstId,
        'item-2',
      ]);
      expect(reconciled.items[1].destinationFolderId, 'photos');
    },
  );

  test('creates, renames, and assigns virtual folders in memory', () {
    var draft = const OrganizationWorkspaceDraft(
      items: [OrganizationWorkspaceItem(id: 'one', sourcePath: '/tmp/one.txt')],
    );
    draft = draft.addFolder(
      const VirtualOrganizationFolder(id: 'folder', name: '圖片'),
    );
    draft = draft.assignItem('one', 'folder');
    draft = draft.renameFolder('folder', '相片');

    expect(draft.folderById('folder')?.name, '相片');
    expect(draft.itemsInFolder('folder').single.id, 'one');
    expect(draft.itemsInFolder(null), isEmpty);

    final returned = draft.assignItem('one', null);
    expect(returned.itemsInFolder(null).single.id, 'one');
    expect(draft.itemsInFolder('folder').single.id, 'one');
  });

  test('assigns a category group without mutating the previous draft', () {
    const draft = OrganizationWorkspaceDraft(
      folders: [VirtualOrganizationFolder(id: 'images', name: '圖片')],
      items: [
        OrganizationWorkspaceItem(id: 'one', sourcePath: '/tmp/one.jpg'),
        OrganizationWorkspaceItem(id: 'two', sourcePath: '/tmp/two.jpg'),
        OrganizationWorkspaceItem(id: 'three', sourcePath: '/tmp/three.txt'),
      ],
    );

    final assigned = draft.assignItems(const ['one', 'two'], 'images');

    expect(assigned.itemsInFolder('images').map((item) => item.id), [
      'one',
      'two',
    ]);
    expect(assigned.itemsInFolder(null).single.id, 'three');
    expect(draft.itemsInFolder(null), hasLength(3));
  });

  test('maps backend category names to localized folder defaults', () {
    expect(OrganizationCategory.fromWireName('image')?.folderName, '圖片');
    expect(OrganizationCategory.fromWireName('archive')?.folderName, '壓縮檔');
    expect(OrganizationCategory.fromWireName('unsupported'), isNull);
  });

  test('previews exact target paths while unassigned files stay in place', () {
    const item = OrganizationWorkspaceItem(
      id: 'one',
      sourcePath: '/downloads/photo.jpg',
      destinationFolderId: 'photos',
    );
    const draft = OrganizationWorkspaceDraft(
      folders: [VirtualOrganizationFolder(id: 'photos', name: '圖片')],
      items: [item],
    );

    expect(
      organizationTargetPath(draft: draft, item: item, rootPath: '/downloads'),
      joinOrganizationPath(
        joinOrganizationPath('/downloads', '圖片'),
        'photo.jpg',
      ),
    );
    expect(
      organizationTargetPath(draft: draft, item: item, rootPath: null),
      isNull,
    );

    const unassigned = OrganizationWorkspaceItem(
      id: 'two',
      sourcePath: '/downloads/notes.txt',
    );
    expect(
      organizationTargetPath(draft: draft, item: unassigned, rootPath: null),
      unassigned.sourcePath,
    );
  });

  test('infers a root only when every source shares one directory', () {
    final directory = Directory.systemTemp.createTempSync('flick-organize-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final other = Directory('${directory.path}/other')..createSync();

    expect(
      inferOrganizationRoot([
        '${directory.path}/one.txt',
        '${directory.path}/two.txt',
      ]),
      directory.path,
    );
    expect(
      inferOrganizationRoot([
        '${directory.path}/one.txt',
        '${other.path}/two.txt',
      ]),
      isNull,
    );
  });

  test('rejects unsafe, reserved, and duplicate virtual folder names', () {
    expect(virtualFolderNameError(''), isNotNull);
    expect(virtualFolderNameError('../圖片'), isNotNull);
    expect(virtualFolderNameError('CON'), isNotNull);
    expect(
      virtualFolderNameError('圖片', existingNames: const ['圖片']),
      '已經有同名的虛擬資料夾',
    );
    expect(
      virtualFolderNameError('images', existingNames: const ['Images']),
      '已經有同名的虛擬資料夾',
    );
    expect(virtualFolderNameError('圖片'), isNull);
  });
}
