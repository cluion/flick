import 'package:flick/domain/preview_list_options.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const records = [
    PreviewListRecord(
      sourceIndex: 0,
      path: '/z/charlie.txt',
      originalName: 'charlie.txt',
      proposedName: 'Gamma.txt',
      size: 30,
      modifiedAt: 300,
    ),
    PreviewListRecord(
      sourceIndex: 1,
      path: '/a/alpha.jpg',
      originalName: 'alpha.jpg',
      proposedName: 'Beta.jpg',
      size: 10,
      modifiedAt: 200,
    ),
    PreviewListRecord(
      sourceIndex: 2,
      path: '/m/bravo.png',
      originalName: 'bravo.png',
      proposedName: 'Alpha.png',
      size: 20,
      modifiedAt: 100,
    ),
  ];

  List<int> indices({
    String query = '',
    PreviewSortField sort = PreviewSortField.addedOrder,
    bool ascending = true,
  }) {
    return visiblePreviewIndices(
      records: records,
      query: query,
      sortField: sort,
      ascending: ascending,
    );
  }

  test('filters across original, proposed, extension, and path', () {
    expect(indices(query: 'charlie'), [0]);
    expect(indices(query: 'beta'), [1]);
    expect(indices(query: 'PNG'), [2]);
    expect(indices(query: '/a/'), [1]);
  });

  test('sorts every supported metadata field', () {
    expect(indices(sort: PreviewSortField.originalName), [1, 2, 0]);
    expect(indices(sort: PreviewSortField.proposedName), [2, 1, 0]);
    expect(indices(sort: PreviewSortField.extension), [1, 2, 0]);
    expect(indices(sort: PreviewSortField.size), [1, 2, 0]);
    expect(indices(sort: PreviewSortField.modifiedTime), [2, 1, 0]);
    expect(indices(sort: PreviewSortField.path), [1, 2, 0]);
  });

  test('reverses primary sort while keeping equal values stable', () {
    expect(indices(sort: PreviewSortField.size, ascending: false), [0, 2, 1]);
    final equal = [records[0], records[0]];
    expect(
      visiblePreviewIndices(
        records: [
          equal[0],
          PreviewListRecord(
            sourceIndex: 1,
            path: equal[1].path,
            originalName: equal[1].originalName,
            proposedName: equal[1].proposedName,
            size: equal[1].size,
            modifiedAt: equal[1].modifiedAt,
          ),
        ],
        query: '',
        sortField: PreviewSortField.size,
        ascending: false,
      ),
      [0, 1],
    );
  });

  test('moves selected paths while preserving their relative order', () {
    const paths = ['a', 'b', 'c', 'd', 'e'];
    const selected = {'b', 'd'};

    expect(
      moveSelectedPreviewPaths(
        paths: paths,
        selectedPaths: selected,
        move: PreviewOrderMove.toStart,
      ),
      ['b', 'd', 'a', 'c', 'e'],
    );
    expect(
      moveSelectedPreviewPaths(
        paths: paths,
        selectedPaths: selected,
        move: PreviewOrderMove.earlier,
      ),
      ['b', 'a', 'd', 'c', 'e'],
    );
    expect(
      moveSelectedPreviewPaths(
        paths: paths,
        selectedPaths: selected,
        move: PreviewOrderMove.later,
      ),
      ['a', 'c', 'b', 'e', 'd'],
    );
    expect(
      moveSelectedPreviewPaths(
        paths: paths,
        selectedPaths: selected,
        move: PreviewOrderMove.toEnd,
      ),
      ['a', 'c', 'e', 'b', 'd'],
    );
  });

  test('reports whether a selected move changes processing order', () {
    const paths = ['a', 'b', 'c'];

    expect(
      canMoveSelectedPreviewPaths(
        paths: paths,
        selectedPaths: const {'a'},
        move: PreviewOrderMove.earlier,
      ),
      isFalse,
    );
    expect(
      canMoveSelectedPreviewPaths(
        paths: paths,
        selectedPaths: const {'a'},
        move: PreviewOrderMove.later,
      ),
      isTrue,
    );
    expect(
      moveSelectedPreviewPaths(
        paths: paths,
        selectedPaths: const {'missing'},
        move: PreviewOrderMove.toEnd,
      ),
      paths,
    );
  });
}
