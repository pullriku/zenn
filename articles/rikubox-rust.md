---
title: "自作Boxで二分探索木を作ってみた！"
emoji: "🎄"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["Rust", "二分探索木", "二分探索", "Box"]
published: true
---

## はじめに

Rustには`Box`というスマートポインタがありますよね。

`Box`はデータをヒープに確保して、スタックにはそのポインタだけを置くという役割を持っています。

本記事は、この`Box`を自作した記録です。
そして、自作`Box`を使うデータ構造として二分探索木を実装してみました。

すべてのコードは以下のリポジトリにあります。

https://github.com/pullriku/rikubox

## `MyBox`の実装

### `MyBox`の定義

`MyBox`はヒープ領域にあるデータのポインタを持ちます。

```rust:box.rs
pub struct MyBox<T> {
    inner: NonNull<T>,
    _marker: PhantomData<T>,
}
```

`inner`がnullでないポインタになっています。また、`PhantomData`というサイズが0の型を持っています。
`PhantomData`はいくつかの用途があるのですが、ここでは「`T`を所有している」ことを明示するために使っています。つまり、`MyBox<T>`には、スコープを抜けて破棄される際に、内部の`T`も破棄する責任があるということです。

:::details PhantomDataについて

昔（`RFC 1238`より前）の仕組みでは、T がポインタの先にしか登場しない型だと、コンパイラが次のように誤解することがありました。

1. `MyBox<T>`は`T`を所有しておらず、ただのポインタの箱にすぎない。
1. ならば `MyBox<T>`が破棄されるとき、`T`の寿命（参照先がまだ生きているか）を気にする必要はない。
1. その結果、`T`が先に消えてしまった状態でも`MyBox<T>`の破棄が許され、破棄処理の中で`T`に触れてしまうと危険（未定義な動作）になり得る。

このために、`PhantomData<T>`を入れて、`T`を所有しているという判定にさせることが必須だったようです。

現在のRustでは、型に`Drop`実装がある場合、「その型は破棄時に型引数 T に触れる可能性がある」と見なされるようになっています。本記事のケースでは Drop 実装があるだけで T を所有している扱いになり、`PhantomData<T>` を追加しなくても破棄順序のチェックは正しく行われるようです。[^phantom]

[^phantom]: 一方、varianceやauto trait、`#[may_dangle]`のために、明示的に追加する必要がある場合もあります。

詳しくは、Rustnomiconが参考になります。

https://doc.rust-lang.org/nomicon/phantom-data.html

それでも、

- 「この型は`T`を所有する」という意図が構造体定義から明確になる
- 将来`Drop`実装の有無や形が変わっても、所有関係の意味が型として残る

という利点があり、`PhantomData`はサイズが0で実行時には影響しないため、フィールドに入れることにしました。

:::

### `new`関数

それではこの構造体の核となる`new`関数を作ります。

```rust:box.rs
impl<T> MyBox<T> {
    pub fn new(value: T) -> Self {
        todo!();
    }
}
```

この中で、メモリを確保して`T`を入れて、そのポインタを`self.inner`に代入する処理を書きます。

まず、`Layout`を作成します。これは、サイズとアラインメントを持つ構造体です。

```rust:box.rs
let layout = alloc::Layout::new::<T>();
```

アラインメントは、データをメモリ上のどの境界に配置するかを表します。

- `i32`(32bit = 4byte)のデータは、アドレスが4の倍数の場所に配置される必要があります。
- `i64`(64bit = 8byte)のデータは、アドレスが8の倍数の場所に配置される必要があります。

これらはCPUの物理的な事情で決まっています。また、Rustでは、正しくないアラインメントは未定義動作に繋がるため、境界は必ず守る必要があります。
もしアラインメントがずれた場所にデータを置くと、CPUによってはアクセスできなかったり、極端に遅くなったりするため、Rustでは厳密に管理されているのです。

メモリ確保の前に、サイズが0の場合にはダミーのポインタ（`dangling`）を作るようにします。

```rust:box.rs
if layout.size() == 0 {
    return Self {
        inner: NonNull::dangling(),
        _marker: PhantomData,
    };
}
```

そして、`layout`を`std::alloc::alloc`関数に渡すと、確保された領域のポインタを取得できます。

```rust:box.rs
let ptr = unsafe { alloc::alloc(layout) }.cast::<T>();
```

実は、私がこのコードを最初に書いたときは、サイズが0の分岐を作っていませんでした。しかし、Rustの[`miri`](https://github.com/rust-lang/miri)という、未定義動作を検出できるツールを使用したところ、エラーになりました。

```txt
running 3 tests
test r#box::tests::drop_is_called_once ... 
error: Undefined Behavior: creating allocation with size 0
  --> src/box.rs:13:28
   |
13 |         let ptr = unsafe { alloc::alloc(layout) }.cast::<T>();
   |                            ^^^^^^^^^^^^^^^^^^^^ Undefined Behavior occurred here
   |
```

サイズ0でメモリ確保を行うことは未定義動作みたいです。このツールのおかげで未定義動作を発見できました。
単体テストを`cargo +nightly miri test`コマンドで実行するなどして確認しておくと安心ですね。[^miri]

[^miri]: RustのNightlyツールチェーンが必要です。また、`rustup component add miri`でコンポーネントの追加が必要です。

もしメモリ確保に失敗したら、`null`ポインタが返ってきます。その場合は、標準ライブラリにある、メモリ確保に失敗した際のハンドラを呼びます。（これを呼ばずに、`Err`や`None`を返す、`try_new`メソッドを作ると、パニックする心配がなくていいかもしれませんね。）

```rust:box.rs
if ptr.is_null() {
    alloc::handle_alloc_error(layout);
}
```

取得した領域に書き込みます。

```rust:box.rs
unsafe { ptr.write(value) };
```

これで、確保した領域にデータを書き込めたため、あとはそのポインタをフィールドに代入して返却します。

```rust:box.rs
Self {
    inner: unsafe { NonNull::new_unchecked(ptr) },
    _marker: PhantomData,
}
```

### 借用

スマートポインタは作れましたが、このままでは中のデータにアクセスできません。そのため、中のデータへの参照を提供する手段を作ります。これは`Deref`と`DerefMut`トレイトを実装することで実現できます。

これらのトレイトを実装すると、`*`演算子を使用して中身にアクセスしたり、代入したりできます。`*`を使った際に、コンパイラが勝手に`deref`や`deref_mut`を呼んでいることにしてくれるのです。

```rust:box.rs
impl<T> Deref for MyBox<T> {
    type Target = T;
    fn deref(&self) -> &T {
        unsafe { self.inner.as_ref() }
    }
}

impl<T> DerefMut for MyBox<T> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        unsafe { self.inner.as_mut() }
    }
}
```

これで、例えば以下のように書けます。

```rust:例
let mut x = MyBox::new(5);

// Derefのおかげで、MyBoxなのに中身のi32として扱える
assert_eq!(5, *x); 

// DerefMutのおかげで、中身を直接書き換えられる
*x = 10;
```

### デバッグ文字列

`T`の中身をデバッグ用で出力する場合のために、`Debug`トレイトを実装しておきましょう。

```rust:box.rs
impl<T: fmt::Debug> fmt::Debug for MyBox<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        (**self).fmt(f)
    }
}
```

### スレッド安全性

`MyBox`は`&self`から`&T`を返すだけで、内部可変性を提供しません。また、同じポインタを複製して二重解放する経路もありません。よって、`T`がスレッド安全なら`MyBox`も安全と言えます。

```rust:box.rs
unsafe impl<T: Send> Send for MyBox<T> {}
unsafe impl<T: Sync> Sync for MyBox<T> {}
```

`Send`を満たしたので、`MyBox`を違うスレッドに送れるようになります。

```rust
let b: MyBox<String> = ...;

std::thread::spawn(move || {
    println!("{}", &*b);
});
```

`Sync`により、共有参照`&`を複数のスレッドで持てるようになります。

```rust
use std::sync::Arc;

let b: Arc<MyBox<Vec<i32>>> = Arc::new(...);

let b2 = b.clone();
std::thread::spawn(move || {
    println!("{}", &*b2);
});
```

### ドロップ

最後の実装は破棄（ドロップ）の処理です。

いきなりメモリを開放してはいけません。もし、中身がネットワークソケットやファイル、`Vec`などなら、デストラクタである`drop`を動かさないといけません。
そのため、まず`T`のドロップを行い、そのあとにメモリを開放します。ポインタの先のドロップを行うには`drop_in_place`関数を使います。メモリの開放は`dealloc`関数です。

ただし、`T`サイズが0のときは、ドロップだけ実行して`dealloc`は行いません。また未定義動作になってしまいます。

```rust:box.rs
impl<T> Drop for MyBox<T> {
    fn drop(&mut self) {
        let layout = alloc::Layout::new::<T>();
        unsafe {
            // Tをdrop
            self.inner.as_ptr().drop_in_place();

            if layout.size() != 0 {
                // メモリを解放
                alloc::dealloc(self.inner.as_ptr().cast(), layout);
            }
        };
    }
}
```

実装は以上です。オリジナルの`Box`ができました。まだ`Clone`を作るなど拡張の余地はありますね。

ここからは、これを使ってちょっとしたデータ構造を作ってみましょう。

## 二分探索木

二分探索できる木構造を作ります。
各ノードは整数を持っています。新しいデータを追加する際に、そのデータが既存のノードの値よりも小さければ「左」に、大きければ「右」へと振り分けて配置していくシンプルなルールを持っています。
こうしてデータを整理しておくことで、後からデータを探すときに「値の大小」を見るだけで進む方向がわかり、高速に検索（二分探索）できるようになります。

https://ja.wikipedia.org/wiki/%E4%BA%8C%E5%88%86%E6%8E%A2%E7%B4%A2%E6%9C%A8

https://zenn.dev/brainyblog/articles/data-structures-intro-binary-trees

### 二分探索木の定義

定義はシンプルです。一番最初に追加されたノード`root`を持っておきます。空っぽの場合は、`Option`が`None`になります。

各ノードでは、値`T`と、子のノード2つを持てるようにしておきます。

ここで、先ほど作った`MyBox`を使っています。もし`MyBox`がないと、`Node`のサイズが無限大になってしまいます。`Node`の中の`left`フィールドの中の`Node`の中の`left`フィールドの`Node`の中の... と続けられるため、これはコンパイラに弾かれます。
`MyBox`を使って、ポインタを入れることにより、サイズが固定になるわけです。

```rust:bst.rs
pub struct BinarySearchTree<T> {
    root: Option<MyBox<Node<T>>>,
}

struct Node<T> {
    value: T,
    left: Option<MyBox<Node<T>>>,
    right: Option<MyBox<Node<T>>>,
}
```

### `new`関数

```rust:bst.rs
impl<T> BinarySearchTree<T> {
    pub fn new() -> Self {
        Self { root: None }
    }
}
```

### アルゴリズムの実装

アルゴリズムを書いていくにあたり、`T`に制約をつけます。探索をするということは、値が大小比較できる必要があるということです。単なる整数だけを登録できるようにするのでもいいのですが、`Ord`トレイトを使えば、いろいろな「大小比較できるもの」を`T`として指定できるようになり便利です。

```rust:bst.rs
impl<T: Ord> BinarySearchTree<T> {
    // todo
}
```

`T: Ord`のところが制約です。

#### 登録

新しい要素を登録します。ノードを順番に巡っていく処理なので再帰を使えば綺麗に書けるのですが、それだと巨大なデータでスタックオーバーフローになってしまいます。というわけで、ここではループで実装します。

```rust:bst.rs
pub fn insert(&mut self, value: T) {
    let mut current_node = &mut self.root;

    while let Some(node) = current_node {
        if value == node.value {
            return;
        }

        if value < node.value {
            current_node = &mut node.left;
        } else {
            current_node = &mut node.right;
        }
    }

    *current_node = Some(MyBox::new(Node::new(value)));
}
```

最初は`self.root`から始めます。すでにデータがあるなら、値の大小比較に基づいて、右の子か左の子を参照していくという作業を繰り返し行います。最終的に`None`が見つかったら、そこに代入します。

重複するデータは許さないため、同じのが見つかったら`return`します。

#### 検索

ある値がこの木に存在するかどうかを調べます。

先程と似通った処理です。違うのは、最初の`if`で、見つかったら`true`を返して終了することになります。

見つからなかったら`false`を返して終了です。

```rust:bst.rs
pub fn contains(&self, value: &T) -> bool {
    let mut current = &self.root;

    while let Some(node) = current {
        if value == &node.value {
            return true;
        }

        if value < &node.value {
            current = &node.left;
        } else {
            current = &node.right;
        }
    }

    false
}
```

データの削除は省略します。ということで実装は以上になります。

### ドロップ時にスタックオーバーフローする問題を回避する

こんなテストを書いてみました。

```rust:bst.rs
#[cfg(not(miri))]
#[test]
fn many_inserts() {
    let mut t = BinarySearchTree::new();
    for v in 0..10_000 {
        t.insert(v);
    }
    // 大量に drop が走る
    drop(t);
}
```

1万件登録して、そのあとに廃棄します。今のままだと、ここでプログラムがスタックオーバーフローします。`Node`の`drop`内でさらに他のノードの`drop`が呼ばれてさらに... と続いていくためです。
これを防ぐために、`drop`もループで処理するように変えてみましょう。`Vec`をスタックとして使います。

```rust:bst.rs
impl<T> Drop for BinarySearchTree<T> {
    fn drop(&mut self) {
        let mut stack: Vec<MyBox<Node<T>>> = Vec::new();

        if let Some(root_node) = self.root.take() {
            stack.push(root_node);
        }

        while let Some(mut node) = stack.pop() {
            if let Some(left) = node.left.take() {
                stack.push(left);
            }
            if let Some(right) = node.right.take() {
                stack.push(right);
            }
        }
    }
}
```

`self.root`から始めて、子が存在すれば`take`してスタックに積みます。`take`は子をNoneにする代わりに、その値を返す関数です。
ループが終わると、`node`は破棄されます。この時、子は絶対に`None`なので、再帰的な処理は起こらずただ破棄されるだけです。
そして`stack`から次のノードを取り出し、同じことを行っていきます。

このようにすれば、関数の再帰でスタックオーバーフローをせずに済みます。

これにてすべての実装は終わりです。`main`やテストを作るなどして動かしてみましょう。
自作の`MyBox`でデータ構造を作って、実際に動かすことができました。

## おわりに

オリジナルの良いツリーができましたね🎄🎁

本記事は「KDIX CS Advent Calendar 2025」に参加しています。

https://qiita.com/advent-calendar/2025/kdixcs
