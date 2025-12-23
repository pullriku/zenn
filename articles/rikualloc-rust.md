---
title: "メモリアロケータを作ってみた！「責務の分離」を低レイヤーでやってみた！"
emoji: "🐊"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["Rust", "メモリ", "メモリ管理", "抽象化"]
published: false
---

メモリアロケータを、トレイト（インターフェース）を活用しながら作ったという記事です。

## はじめに

「メモリアロケータって何をやっているんだろう？」と、ふと気になりました。
メモリアロケータとは、OSやハードウェアから「大きなメモリの塊」を受け取り、それをプログラムが利用しやすいサイズ（構造体や配列の大きさ）に切り分けて提供してくれる、メモリとプログラマの仲介人です。

メモリアロケータは様々な場面で登場します。

- OSを開発する際は、ハードウェアのメモリを「ページ」という単位で管理しつつ、カーネル内部で細かいサイズの確保も必要になります。
- アプリケーション開発でも、メモリを管理する必要があります。Rustの`Vec`や`String`、Pythonのオブジェクトは、メモリを確保して、そこへの参照をローカル変数に保持する形になっています。
- さらに追加のアロケータを使うこともできます。例えば、大量に小さなオブジェクトを確保・破棄する場合は、巨大な配列を作って、そこに格納していきます。用済みになれば、その配列を破棄するだけです。管理方法は、最初から順番にオブジェクトを詰めていくBumpアロケータが一般的ですかね。

こうして見ると、メモリアロケータがやっていることは大きく2つに分けられます。

- **調達（確保）**
  ある程度まとまったメモリをどこかから取ってくる。

- **管理**
  そのメモリを小分けにして配る。場合によっては、回収し、再利用できるようにする。

これを抽象化すれば、調達と確保の実装を色々入れ替えて**遊べる**のではないかと考えました。
この図のような感じです。（細かい用語は知らなくてOK）

![レイヤー構造のメモリ管理図。上段は「レイヤー1：メモリ管理層」で、Bump と Free List を含む。下段は「レイヤー0：メモリ調達層」で、OS Heap と大きい配列を含む。管理層が下層にメモリを要求し（ちょうだい）、下層からまとめてメモリが返される（あげる！ごっそり）関係を矢印で示している。](/images/articles//rikualloc-rust/layers_2.png)

また、ユーザのプログラムからアロケータを呼び出せるように、適切なインターフェースに対応させます。（レイヤー2）

![メモリアロケータの多層構造を示す図。最上段は「レイヤー3：ユーザ」で、String、Vec、HashMap、BTreeSet、Box、Rc などの便利なデータ構造や構文木の構築が行われる。下に「レイヤー2：インタフェース」があり、直接呼び出し、GlobalAlloc、Allocator API を通じて必要な分だけメモリ管理層に要求する。さらに下の「レイヤー1：メモリ管理層」では Bump や Free List がメモリを管理し、最下段の「レイヤー0：メモリ調達層」から OS Heap や大きい配列としてメモリをまとめて受け取る関係を矢印で示している。](/images/articles//rikualloc-rust/layers_4.png)

というわけでこの記事では、L0、L1、L2に分離したメモリアロケータを自作してみます。
Rustで自作メモリアロケータを作りながら、`MemorySource`（メモリ供給）と `MutAllocator`（割り当て戦略）を分ける形で、責務の分離を低レイヤーでやってみた感じです。

すべてのコードは以下のリポジトリにあります。

https://github.com/pullriku/rikualloc

## 実装

今回はゼロからstep-by-stepでの解説ではなく、実装を紹介していきます。

### ライブラリのあり方とlib.rs

今回のアロケータは、OSのある・なしや、グローバルアロケータであるかどうかにかかわらず、どこでも使えるようにしたいと思いました。
なので、`no_std`でも使えるようにしています。Rustの標準ライブラリ「`std`」はOSに依存しています。そのため、OSのない環境にも対応するには、`no_std`を指定して`std`を使わない設定をする必要があります。

今回は、デフォルトで`std`を使用するが、外したければ`no_std`にできるという構成にします。

プロジェクトの設定ファイル`Cargo.toml`で、`feature`を定義します。

```toml:Cargo.toml
[features]
default = ["std"]
std = []
```

`std`というfeatureを作り、それをデフォルトにしています。featureとは、コードをコンパイルするときに指定できるオプションのことです。これを切り替えて、どの機能を含めるかを選択できます。

このfeaturesを`lib.rs`で使います。

```rust:lib.rs
#![no_std]
#![feature(allocator_api)]

#[cfg(feature = "std")]
extern crate std;

pub mod allocator;
pub mod mutex;
pub mod source;
```

`#![no_std]`と`#[cfg(feature = "std")]`を使って、一旦`no_std`にするが、`std` featureが指定されていたら`std`を使うようにしています。

それでは、レイヤー0の`allocator`モジュールから見ていきましょう。

### `source`モジュール

レイヤーという概念はトレイトで表します。

レイヤー0の、メモリを取ってくる機能は以下のように定義しました。

```rust:source.rs
pub trait MemorySource {
    unsafe fn request_chunk(&mut self, layout: Layout)
    -> Option<NonNull<[u8]>>;

    unsafe fn release_chunk(&mut self, ptr: NonNull<u8>, layout: Layout);
}
```

`request_chunk`と、`release_chunk`という2つのメソッドを持っています。
リクエストの方は、サイズとアライメントを表す`Layout`を受け取り、ポインタを返します。
`Layout`は`std::alloc`で定義されている型で、必要なメモリサイズ（`size`）とアラインメント（`align`）の2つをまとめて表現する型です。`release`も作りましたが今回は使えませんでした。
サイズとアライメントは正しい組み合わせである必要があるため、この型でまとめて管理すると便利です。実際にRustの内部でも使われています。

アライメントは、データをメモリ上のどの境界に配置するかを表します。

- `i32`(32bit = 4byte)のデータは、アドレスが4の倍数の場所に配置される必要があります。
- `i64`(64bit = 8byte)のデータは、アドレスが8の倍数の場所に配置される必要があります。

これらはCPUの物理的な事情で決まっています。また、Rustでは、正しくないアライメントは未定義動作に繋がるため、境界は必ず守る必要があります。

`Option<NonNull<[u8]>>`についても触れておきます。
単なるポインタと`null`を使ってもいいのですが、`Option`で有効な値かを表し、有効なら`NonNull`にポインタを格納するようにすると、`null`ポインタへのアクセスが避けられます。
また、ポインタの型が`u8`（byte）じゃなくて、`[u8]`（byteのスライス）になっていますね。これは「fat pointer」を使うためです。スライスの参照やポインタには、「長さ」を含めることができます。今回は、ポインタと確保した領域の長さをまとめて返すため、`[u8]`を使います。

このトレイトを実装して、レイヤー0を作っていきます。

### Static Buffer

一番シンプルな`MemorySource`として、ただの静的配列を提供する実装を作ります。
簡単な実装にしたいので、1回のアロケートで配列の全部を渡してしまいます。それ以降のアロケートは失敗するようにします。

```rust:source/static_buff.rs
pub struct StaticBuffer<const N: usize> {
    buffer: UnsafeCell<[MaybeUninit<u8>; N]>,
    taken: AtomicBool,
}

unsafe impl<const N: usize> Sync for StaticBuffer<N> {}
```

未初期化（`MaybeUninit`）のバッファがが`N`バイト分あります。使用済みかを表す`take`も含めました。
見慣れない`UnsafeCell`と`AtomicBool`も使っています。

- `UnsafeCell`は、不変参照（共有参照）である`&`から内部データを変更することができます。
- `AtomicBool`は、データ競合なしで更新できる`bool`です。

また、`StaticBuffer`には`unsafe impl Sync`を付けています。これは「共有参照 `&StaticBuffer`を複数スレッドで持ってよい」ことを型に許可するものです。
本来、`UnsafeCell`を含む型は自動で`Sync`になりません（内部可変性があるため）。しかしこの`StaticBuffer`は

- 中身のバッファを1回だけ返す
- 状態（taken）は AtomicBool で同期する

という制約を守ることで、共有しても破綻しない設計にしています。

この構造体に`MemorySource`を実装してみましょう。

```rust:source/static_buff.rs
impl<const N: usize> MemorySource for &StaticBuffer<N> {
    unsafe fn request_chunk(
        &mut self,
        layout: Layout,
    ) -> Option<NonNull<[u8]>> {
      todo!()
    }

    unsafe fn release_chunk(&mut self, _ptr: NonNull<u8>, _layout: Layout) {}
}
```

返却はできない仕様にするため、`release_chunk`は空っぽにします。
メモリ取得の`request_chunk`の実装を大まかにご紹介します。

まず、バッファのポインタを取ります。

```rust
let base: *mut u8 = unsafe { (*self.buffer.get()).as_mut_ptr().cast::<u8>() };
```

`UnsafeCell`の内部は`get`で取得できます。そうして取ってきた配列`[MaybeUninit<u8>; N]`の先頭のポインタ`MaybeUninit<u8>`を取ります。そして、以降は`u8`のポインタとして扱います。

これでポインタを作れましたが、これをそのまま返すわけにはいきません。ポインタは要求されたアライメントを満たす必要があります。そこでパディングを求めます。

パディングはアライメントに合わせるために挿入する「空白」のバイト数です。
例えば、現在のアドレスが`6`で、必要なアライメントが`4`のとき、開始アドレスは`4`で割り切れる必要があります。`6`以降で最初にその条件を満たすのは`8`なので、アドレスを`2`だけ進めて`8`にします。この進めた2byteがパディングです。

```rust
let pad = base.align_offset(layout.align());
if pad == usize::MAX || pad > N {
    return None;
}
```

`align_offset`メソッドで簡単に求められます。失敗時（`usize::MAX`が返るとき）とパディングが配列より大きいときは、`None`を返します。`ポインタ+パディング`でオーバーフローするときなどで`usize::MAX`になるみたいです。

パディングがわかったので、実際にユーザが使えるバイト数を求めてみましょう。これが要求より小さかったら`None`を返します。

```rust
let avail = N - pad;
if avail < layout.size() {
    return None;
}
```

ここまででサイズの確認が終わりました。あとはこの構造体を「使用済み」にして、ポインタを返却するだけです。
そのために、`taken`フィールドが`false`であることを確認してから、`true`にします。
これには、`AtomicBool::compare_exchange`メソッドを使います。

```rust
if self
    .taken
    .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
    .is_err()
{
    return None;
}
```

もし既に使用済みならエラーになるため、`is_err`が`true`になり`None`を返します。

あとはユーザが使うポインタを返却します。
`null`でないポインタ`NonNull`と、ユーザが使えるバイト数を返します。スライスのポインタはfat pointerなため、両方を含めることができます。

```rust
let start = unsafe { base.add(pad) };
let nn = NonNull::new(start)?;

Some(NonNull::slice_from_raw_parts(nn, avail))
```

配列をメモリソースとして使う実装ができました。
次はOSに頼み込んでメモリを持ってくる実装を書いてみましょう。

### OS Heap

OSのヒープ領域でメモリを確保します。
特にフィールドはいらないため、空の構造体を作ります。

```rust
pub struct OsHeap;
```

まず下準備です。あまり小さいメモリを高頻度でOSに要求すると遅くなります。なのである程度一気に確保したいですね。OSは「ページ」というまとまりでメモリを管理しており、このサイズで取得するようにすると、都合が良さそうです。

ということで下準備として、ページサイズを取得する処理を書きます。`static`にページサイズを保存します。

```rust
static PAGE_SIZE: AtomicUsize = AtomicUsize::new(0);

fn page_size() -> usize {
    let page_size = PAGE_SIZE.load(Ordering::Relaxed);
    if page_size != 0 {
        return page_size;
    }
    let result = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    let page_size = if result > 0 { result as usize } else { 4096 };
    PAGE_SIZE.store(page_size, Ordering::Relaxed);
    page_size
}
```

`page_size`が`0`なら`sysconf`で取得して保存します。`page_size`が`0`でない場合はそのまま使います。[^page_size]

[^page_size]: `OsHeap`が`new`された際にページサイズをフィールドに保存してもいいのですが、それだと`new`が`const fn`になれず、結果として`OsHeap`が`static`変数に入れられなくなってしまいます。他の方法として、`AtomicUsize`をフィールドに持って、`page_size`をメソッドにしてもいいと思います。

それではトレイトを実装していきます。

```rust:source/os_heap.rs
impl MemorySource for OsHeap {
    unsafe fn request_chunk(
        &mut self,
        layout: Layout,
    ) -> Option<NonNull<[u8]>> {
        todo!();
    }

    unsafe fn release_chunk(
        &mut self,
        ptr: NonNull<u8>,
        layout: Layout,
    ) {
        todo!();
    }
}
```

#### `request_chunk`

確保するサイズをページサイズに切り上げて、OSに要求するだけなので、処理はシンプルです。

まずサイズをページサイズの倍数に切り上げます。

```rust
let alloc_size = Layout::from_size_align(layout.size(), page_size())
    .ok()?
    .pad_to_align()
    .size();
```

これにより、要求したサイズよりも大きなサイズが返ることがあります。

OSへの要求には、連続した領域を確保する仕組みである、`mmap`を使います。これはOSの`mmap`システムコールを呼んでいます。成功すると、その領域の先頭アドレス（ポインタ）が返ります。

```rust
let ptr = unsafe {
    libc::mmap(
        ptr::null_mut(),
        alloc_size,
        libc::PROT_READ | libc::PROT_WRITE,
        libc::MAP_PRIVATE | libc::MAP_ANONYMOUS,
        -1,
        0,
    )
};
```

- `MAP_ANONYMOUS`はファイルに紐づかないただのメモリ領域を表します。`mmap`ではファイルをメモリにマップすることもできるため、これで無効にします。
- `MAP_PRIVATE`はこのプロセス内だけの領域であることを表します。他のプロセスと共有しないということです。
- `PROT_READ | PROT_WRITE`は読み書きを許可します。

返ってくる領域は通常ページでアラインされています。

割り当てに失敗していないかを確認してから返却しましょう。

```rust
if ptr == libc::MAP_FAILED {
    return None;
}

let slice_ptr =
    ptr::slice_from_raw_parts_mut(ptr.cast::<u8>(), alloc_size);

NonNull::new(slice_ptr)
```


#### `release_chunk`

解放は`munmap`(memory unmap)を使います。

```rust:source/os_heap.rs
unsafe fn release_chunk(&mut self, ptr: NonNull<u8>, layout: Layout) {
    if layout.size() == 0 {
        return;
    }

    let result = unsafe {
        libc::munmap(ptr.as_ptr().cast::<libc::c_void>(), layout.size())
    };

    debug_assert_eq!(result, 0);
}
```

今記事での`MemorySource`の実装はこの2つになります。`enum`ではなくトレイトとして定義しているので、必要に応じていろいろな実装を増やすことができます。
次は、メモリを管理するレイヤー1の実装を見ていきましょう。

### `allocator`モジュール

レイヤー1を表すトレイトは、`MutAllocator`です。可変参照（排他参照）を取るため、`Mut`と命名しました。基本的に、アロケータは複数スレッドからアクセスされるため、不変参照（共有参照）を使って処理をする必要があります。しかし、今回はスレッドのことを考えたくないので、可変参照でアロケータを作って、`Mutex`でラップすることにします。

```rust:allocator.rs
pub trait MutAllocator {
    unsafe fn alloc(&mut self, layout: Layout) -> Option<NonNull<[u8]>>;
    unsafe fn dealloc(&mut self, ptr: NonNull<u8>, layout: Layout);
}
```

実装するアロケータは`BumpAllocator`です。これはとても単純なアロケータで、先頭から要素を詰めていくだけです。割り当てた要素の解放はありません。使っている領域がいっぱいになると、新しい領域をレイヤー0から取ってきて、また先頭から詰めていきます。

```rust:source/bump_allocator.rs
pub struct BumpAllocator<S: MemorySource> {
    source: S,

    ptr: NonNull<u8>,
    end: NonNull<u8>,

    head: Option<NonNull<ChunkNode>>,
}

unsafe impl<S: MemorySource + Send> Send for BumpAllocator<S> {}

pub struct ChunkNode {
    next: Option<NonNull<ChunkNode>>,
    ptr: NonNull<u8>,
    layout: Layout,
}
```

このアロケータはレイヤー0を表す`source`と、管理に必要なポインタを持っています。
`ChunkNode`というのは、レイヤー0からもらったメモリのまとまりのことです。`next`フィールドをつなげていって、連結リストを作ります。このリストは`BumpAllocator`を解放するのに使います。

個々の要素を個別に解放することはありませんが、このアロケータ自体が捨てられるときが来るかもしれません。その際に、リンクを辿って、全ての`ChunkNode`を解放(`release_chunk`)します。

それでは、実装を見ていきましょう。

```rust:source/bump_allocator.rs
impl<S: MemorySource> MutAllocator for BumpAllocator<S> {
    unsafe fn alloc(&mut self, layout: Layout) -> Option<NonNull<[u8]>> {
        todo!();
    }

    unsafe fn dealloc(&mut self, _ptr: NonNull<u8>, _layout: Layout) {}
}
```

#### `alloc`

`alloc`は要求された量のメモリを確保します。

要求された量が`0`のときは、特別にダミーの長さ0のスライスを返します。

```rust:allocator/bump_allocator.rs
if layout.size() == 0 {
    let ptr = ptr::without_provenance_mut::<u8>(layout.align());
    let nn = unsafe { NonNull::new_unchecked(ptr) };

    return Some(NonNull::slice_from_raw_parts(nn, 0));
}
```
`without_provenance_mut`でprovenanceを持たないダミーポインタを作ります。
provenanceは、そのポインタがどこから来たのかという情報です。ポインタは、「このメモリ塊に属している」というタグみたいなものを一緒に持っている感じです。そのタグがない（or 間違ってる）ポインタでメモリにアクセスすると、未定義動作（UB）になり得ます。
この情報は、コンパイラによる最適化に使われたり、`cargo　miri`で未定義動作を検出するために使われるみたいです。

例えば、`Vec`からポインタを作ると、ポインタはその`Vec`のアロケーション由来になります。

```rust
let p = Vec::<u8>::with_capacity(10).as_mut_ptr();
```

しかし、整数にしてから再びポインタにすると、provenanceは失われます。

```rust
let addr = p as usize;
let q = addr as *mut u8;
```

という感じで、整数をポインタにする操作は避けて実装します。

話を戻すと、`without_provenance_mut`は出自情報を持たないポインタを作るという関数です。すなわち、このポインタをDerefしたりアクセスしたりしてはいけません。


