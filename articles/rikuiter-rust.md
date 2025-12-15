---
title: "イテレータを作ってみた！ゼロから作る遅延評価とメソッドチェーン"
emoji: "⛓️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["Rust", "イテレータ", "iterator"]
published: true
---

## はじめに

普段のプログラミングで`map`や`filter`、使っていますか？

RustやPythonといった現代的な言語において、`for`文は単に数値をカウントアップするだけの構文ではありません！

```python
for i in [1, 2, 3, 4, 5]:
    print(i)
```

RustでもPythonでも、`for`文は「配列の要素を順番に取り出す魔法」ではなく、実際には「イテレータという道具から、要素がなくなるまで`next`を呼び出し続ける」という地道な作業を自動化してくれているんです。

Rustのイテレータは特に強力で、**遅延評価**という特性を持っています。
`map`や`filter`をいくら繋げても、実際にデータが必要になる（`collect`したり`for`で回したりする）瞬間まで、計算は一切行われません。**データが必要になるまでは、ただ「次に何をするか」の設計図だけが積み重なっていくだけです。**

本記事では、そんなRustのイテレータを実際にゼロから作ってみて、

- `map` / `filter` がなぜ遅延評価になるのか
- メソッドチェーンがどうやって積み重なるのか

を解説していきます！

「え、イテレータって配列を回す便利機能じゃなくて、`next()`を呼び続ける仕組みなの……？」となった人ほど、最後まで読むと気持ちよく繋がるはずです。

## この記事のゴール

最終的に、こんなコードが動くところまで持っていきます。

```rust
let vec: Vec<usize> = Counter::new()
    .map(|x| x * 10)
    .filter(|x| x % 4 == 0)
    .skip(1)
    .take(10)
    .collect_vec();

println!("{vec:?}"); // [20, 40, 60, 80, 100, 120, 140, 160, 180, 200]
```

`Counter`というイテレータを作り、そこから`map`や`filter`、`skip`、`take`といったメソッドをチェーンしていきます。最後に`collect_vec`でベクタに変換して結果を得ます。

## イテレータの基本

Rustのイテレータは、`Iterator`トレイトを実装することで作成できます。`Iterator`トレイトは、以下のように定義されています。

```rust
pub trait Iterator {
    type Item;
    fn next(&mut self) -> Option<Self::Item>;
    // たくさんのメソッドが並ぶ...
}
```

`Iterator`トレイトを実装するためには、`next`メソッドを定義する必要があります。`next`メソッドは、イテレータから次の要素を取得し、要素が存在しない場合は`None`を返します。
**このメソッドがイテレータを1つ進めるための唯一の入口です。**

トレイトとは、「この機能を持っていますよ」という証明書のようなものです。トレイトを「実装」するには、そのトレイトが要求するメソッドをすべて定義しなければなりません。ということは、トレイトを実装した構造体は、そのメソッドを持つことが保証されます。
すなわち、イテレータは`next`メソッドを持っていることが保証されるわけです。

`type Item;`は関連型と呼ばれ、イテレータが返す要素の型を指定します。

そして、この`Iterator`トレイトには、`map`や`filter`など、多くの便利なメソッドがデフォルトで実装されています。これらのメソッドは、イテレータを変換したり、フィルタリングしたりするために使用されます。

構造体を作って`Iterator`を実装すると、その構造体はイテレータとして振る舞うことができます。つまり、`for`文で回したり、`collect`メソッドでコレクションに変換したりできるようになります。

このようなイテレータを自分でイチから作ってみましょう！


### 準備

すべての実装は以下のGitHubリポジトリで公開しています。

https://github.com/pullriku/rikuiter

Rustプロジェクトを新規作成します。まずは`src/main.rs`にコードを書いていきます。
`--bin`のあとはお好きな名前で構いません。

```bash
cargo new --bin rikuiter
cd myiter
```

## 1. 基礎

### トレイトの定義

最初に、イテレータの基礎となるトレイトを定義します。
このトレイトにメソッドを追加していくことで、イテレータの振る舞いを拡張していきます。

```rust:src/main.rs
trait MyIterator {
    type Item;
    fn next(&mut self) -> Option<Self::Item>;
}
```

### イテレータの実装

それでは、具体的なイテレータを実装していきましょう。ここでは、0から始まる連続した整数を生成する`Counter`イテレータを作成します。

```rust:src/main.rs
struct Counter {
    count: usize,
}

impl Counter {
    fn new() -> Counter {
        Counter { count: 0 }
    }
}
```

この時点では普通の構造体です。
Rustでは`return`キーワードは省略可能なので、`Counter { count: 0 }`のように書くだけで`Counter`型のインスタンスが返されます。また、ブロック`{}`が式になっており、`if`も値を返せます。
以降も同様に省略形を用いてスッキリと書いていきます。

先ほどの`MyIterator`トレイトを`Counter`に実装して、イテレータとして振る舞うようにします。

```rust:src/main.rs
impl MyIterator for Counter {
    type Item = usize;
    fn next(&mut self) -> Option<Self::Item> {
        let result = self.count;
        self.count += 1;
        Some(result)
    }
}
```

`next`メソッドの実装は、`count`フィールドを返し、その後に`count`をインクリメントしています。これにより、呼び出すたびに1ずつ増加する整数が生成されます。

`Option`型は、値が存在しない可能性を表現するために使われます。存在しない場合は`None`、存在する場合は`Some(value)`で値を包んで返します。ここでは、常に値が存在するので`Some(result)`を返しています。

もうひとつ、要素数が有限であるイテレータも作ってみましょう！

```rust:src/main.rs
struct RangeUsize {
    start: usize,
    end: usize,
}

impl RangeUsize {
    fn new(start: usize, end: usize) -> RangeUsize {
        RangeUsize { start, end }
    }
}
```

RustやPythonでおなじみの、範囲を表す`Range`型っぽいものです。簡略化のために、数値型は`usize`に固定します。`usize`は配列やスライスのインデックスとして使われる、プラットフォーム依存サイズの符号なし整数型です。

こちらにもイテレータを実装しましょう。今回は、`start`から`end`までの数値を順番に返し、`end`に達したら`None`を返すようにします。すなわち、`start`以上`end`未満の数値を生成するイテレータです。

```rust:src/main.rs
impl MyIterator for RangeUsize {
    type Item = usize;
    fn next(&mut self) -> Option<Self::Item> {
        if self.start < self.end {
            let result = self.start;
            self.start += 1;
            Some(result)
        } else {
            None
        }
    }
}
```

`start`をどんどん加算していき、`end`に達したら`None`を返すようにしています。
これでイテレータの実装が2つできましたね！動かしてみましょう！

### イテレータの利用

構造体を作成し、可変（`mut`）の変数に入れて、`next`を繰り返し呼び出します。
`while let`構文を使うと`Some`が返ってくる限りループを続けられるので便利です。
内部の`start`が1、2、3、と増加していって、4に達したら`None`が返ってループが終了します。

```rust:src/main.rs
fn main() {
    println!("== MyIteratorを手で回すデモ ==");

    let mut range = RangeUsize::new(1, 4);
    while let Some(x) = range.next() {
        println!("Raw Range: {}", x);
    }
}
```

```txt
== MyIteratorを手で回すデモ ==
Raw Range: 1
Raw Range: 2
Raw Range: 3
```

イテレータは`for`文でも回せます。`for`文はイテレータの`next`を自動で呼び出してくれるので、コードがスッキリします。使ってみましょう！

```rust:src/main.rs❌
for x in RangeUsize::new(1, 4) {
    println!("StdIter: {}", x);
}
```

💣💥💥💥
あれ？　エラーになりますね。

```txt
error[E0277]: `RangeUsize` is not an iterator
  --> src/main.rs:69:14
   |
69 |     for x in RangeUsize::new(1, 4) {
   |              ^^^^^^^^^^^^^^^^^^^^^ `RangeUsize` is not an iterator
   |
help: the trait `std::iter::Iterator` is not implemented for `RangeUsize`
  --> src/main.rs:25:1
   |
25 | struct RangeUsize {
   | ^^^^^^^^^^^^^^^^^
   = note: required for `RangeUsize` to implement `std::iter::IntoIterator`
```

イテレータのはずなのに、`RangeUsize is not an iterator`と言われてしまいました。
これは、Rustの標準ライブラリが提供する`Iterator`トレイトを実装していないためです。
先ほど「イテレータを実装しましょう」と言ったのは、あくまで自作の`MyIterator`トレイトに対してでした。
Rustの`for`文は標準ライブラリの`Iterator`トレイトを実装している型でしか使えません。

というわけで、`MyIterator`を実装する型を包んで標準ライブラリの`Iterator`トレイトを実装するラッパーを作成します。これにより、本記事で作成したオリジナルのイテレータを標準ライブラリのイテレータとして扱えるようになります。

```rust:src/main.rs
struct StdIter<T>(T);

impl<T: MyIterator> Iterator for StdIter<T> {
    type Item = T::Item;

    fn next(&mut self) -> Option<Self::Item> {
        self.0.next()
    }
}
```
`T`は`MyIterator`を実装している何らかの型です。
`MyIterator`を実装しているということは、絶対に`Item`型と`next`メソッドを持っているので、それらをそのまま標準ライブラリの`Iterator`トレイトに橋渡ししています。

また、`struct`の定義で`StdIter<T>(T);`と書くと、タプル構造体という形になります。フィールド名を持たず、インデックスでアクセスする構造体です。今回はフィールドが1つだけなので、この形がシンプルで良いでしょう。

これで`for`文で回せるようになりました！試してみましょう。

```rust:src/main.rs
println!("\n== StdIterでラップしてforループを使う ==");

let range_std = StdIter(RangeUsize::new(1, 4));
for x in range_std {
    println!("StdIter: {}", x);
}
```

```txt
== StdIterでラップしてforループを使う ==
StdIter: 1
StdIter: 2
StdIter: 3
```

先ほどとは違い、変数定義で`mut`を付けなくても動きます。これは、`for`文に`range_std`を渡すときに、イテレータが所有権ごとムーブされるためです。`range_std`変数を直接書き換えるわけではないので、`mut`は不要です。
このようなちょっとした違いでも、所有権を意識する必要があるのがRustの面白いところですね。誰が値を所有しているのか、把握しながら読んで/書いてみてください。間違ってもコンパイルエラーになるので安心ですよ。

さて、`next`を呼ぶだけではシンプルすぎますね。少し標準ライブラリの機能を使ってみましょう。

#### メソッドチェーンをしてみる！

標準ライブラリの`Iterator`トレイトには、`map`や`filter`、`skip`、`take`など、多くの便利なメソッドが用意されています。これらのメソッドは、イテレータを変換したり、フィルタリングしたりするために使用されます。

`StdIter`のおかげてこれらのメソッドが使えるようになったので、実際に使ってみましょう！

```rust:src/main.rs
println!("\n== 標準メソッドを使いまくる ==");
let counter_std = StdIter(Counter::new());
let vec: Vec<usize> = counter_std
    .map(|x| x * 10)
    .filter(|x| x % 4 == 0)
    .skip(1)
    .take(10)
    .collect();

println!("Result: {vec:?}");
```

```txt
== 標準メソッドを使いまくる ==
Result: [20, 40, 60, 80, 100, 120, 140, 160, 180, 200]
```

本記事ではこれらのメソッドを実装していき、最終的には **`StdIter`ラッパーを使わずに、直接`Counter`イテレータでメソッドチェーンができるようにしていきます！**

## 2. 消費系アダプタ

この記事では、どの段階でも実際にコードが動くことを重視したいのです。
そのため、まずはイテレータを消費する**消費系アダプタ**を実装します。これは、イテレータの要素をすべて消費して、何らかの集計結果を返すメソッドです。
つまり、イテレータで処理をしたあと、一番最後に呼び出すメソッドになります。
これを実装することで、このあとイテレータを変換する機能を実装した際に、実際に動作確認ができるようになります。

どれも突き詰めると`next()`を`None`が返るまで呼び続けているだけなので、実装はシンプルです。

### リファクタリング: モジュール分割

今は`src/main.rs`に全部コードを書いていますが、コードが増えてきたのでモジュール分割をして整理しましょう。`main.rs`からモジュールを呼んでもいいのですが、今回は`lib.rs`を作成して、ライブラリとしてのコードをそこにまとめる形にします。

`main.rs`は`main`関数とイテレータの実装、`lib.rs`にモジュール宣言、`iter.rs`に`MyIterator`トレイトをまとめました。

:::details 実装

```rust:src/lib.rs
pub mod iter;
```

```rust:src/iter.rs
use std::ops;

pub trait MyIterator {
    type Item;
    fn next(&mut self) -> Option<Self::Item>;
}

pub struct StdIter<T>(pub T);

impl<T: MyIterator> Iterator for StdIter<T> {
    type Item = T::Item;

    fn next(&mut self) -> Option<Self::Item> {
        self.0.next()
    }
}
```

```rust:src/main.rs
use rikuiter::iter::MyIterator;

struct Counter {
    count: usize,
}

impl Counter {
    fn new() -> Counter {
        Counter { count: 0 }
    }
}

impl MyIterator for Counter {
    type Item = usize;
    fn next(&mut self) -> Option<Self::Item> {
        let result = self.count;
        self.count += 1;
        Some(result)
    }
}

struct RangeUsize {
    start: usize,
    end: usize,
}

impl RangeUsize {
    fn new(start: usize, end: usize) -> RangeUsize {
        RangeUsize { start, end }
    }
}

impl MyIterator for RangeUsize {
    type Item = usize;
    fn next(&mut self) -> Option<Self::Item> {
        if self.start < self.end {
            let result = self.start;
            self.start += 1;
            Some(result)
        } else {
            None
        }
    }
}

fn main() {
    // これから実装
}
```

:::

### 実装

### `count`メソッド

まずは要素の個数を数える`count`メソッドを実装してみましょう。

`MyIterator`トレイトに`count`メソッドを追加します。実装は非常にシンプルで、`Some`が返るたびに変数をインクリメントしていくだけです。

```rust:src/iter.rs
fn count(mut self) -> usize
where
    Self: Sized,
{
    let mut count = 0;

    while self.next().is_some() {
        count += 1;
    }

    count
}
```

シンプルですが、注目すべき点が2つあります。

まず、引数に注目してください。`mut self`（`mut self: Self`の省略形。`Self`は`MyIterator`）となっています。これにより、自身の所有権をこのメソッドにムーブし、この関数の中で寿命が尽きるようにします。イテレータは一度消費されると再利用できないので、このようにするのが自然です。今回は可変にしたいので、追加で`mut`をつけました。他にも`&self`や`&mut self`といった受け取り方があります。

そして、唐突に`where`と書かれており、`Self: Sized`と制約が付いています。`Sized`トレイトは、型のサイズがコンパイル時に確定していることを表します。
ここで`Self: Sized`が必要になる理由は、`count`が`self`を値（所有権）として受け取るメソッドだからです。サイズが不定な型（スライスやトレイトオブジェクトなど）は、値としてスタックに置けないため`self`をそのまま受け取れません。そのため、`self`を値で受け取るメソッドには`Self: Sized`が必要になります。
（指定し忘れてもコンパイラがエラーを出してくれます。）

### `for_each`メソッド

戻り値がない`for_each`は便利です。イテレータの各要素に対して副作用のある処理を実行します。

```rust:src/iter.rs
fn for_each<F>(mut self, mut f: F)
where
    F: FnMut(Self::Item),
    Self: Sized,
{
    while let Some(x) = self.next() {
        f(x);
    }
}
```

ユーザーが定義した関数やクロージャ（正確にはクロージャも含む“呼び出し可能な値”）を受け取り、各要素に適用します。
関数の型は`F: FnMut(Self::Item)`とし、各要素（`Item`）を所有権ごと引き渡しています。

実は`FnMut`以外にも似たようなトレイトがあります。

https://qiita.com/hiratasa/items/c1735dc4c7c78b0b55e9

ここで `FnMut`を選んだのは、クロージャが内部に状態を持ってそれを更新できるようにするためです。たとえば次のように、外側の変数を可変でキャプチャし、呼び出すたびに中身が変わるクロージャも許容されます。

```rust
let mut sum = 0;
let closure = |x| {
    // &mut sum をキャプチャしている
    sum += x;
};
```

### 他にも色々

他にもメソッドをたくさん追加すると便利で面白くなります。以下にいくつか例を示します。

`last`メソッドは、イテレータの最後の要素を返します。変数に繰り返し代入していき、最後に残ったものを返すだけです。

```rust:src/iter.rs
fn last(mut self) -> Option<Self::Item>
where
    Self: Sized,
{
    let mut last = None;
    while let Some(x) = self.next() {
        last = Some(x);
    }
    last
}
```

`nth`メソッドは、イテレータのn番目の要素を返します。`next`をn回呼び出してから、さらに1回呼び出してその結果を返します。このあともイテレータを使い続けられるように、`&mut self`で受け取ります。

```rust:src/iter.rs
fn nth(&mut self, n: usize) -> Option<Self::Item> {
    for _ in 0..n {
        self.next()?;
    }
    self.next()
}
```

`collect_vec`メソッドは、イテレータの要素をすべてベクタに収集して返します。空のベクタを作成し、`next`で要素を取り出してベクタに追加していきます。

```rust:src/iter.rs
fn collect_vec(self) -> Vec<Self::Item>
where
    Self: Sized,
{
    let mut vec = Vec::new();

    self.for_each(|x| vec.push(x));

    vec
}
```

`fold`メソッドは、イテレータの要素を畳み込んで1つの値にまとめます。初期値と畳み込み関数を受け取り、各要素に対して関数を適用していきます。

```rust:src/iter.rs
fn fold<B, F>(mut self, mut acc: B, mut f: F) -> B
where
    F: FnMut(B, Self::Item) -> B,
    Self: Sized,
{
    while let Some(x) = self.next() {
        acc = f(acc, x);
    }
    acc
}
```

`fold`を使って、こんなのも作れます。

```rust:src/main.rs
fn sum(self) -> Self::Item
where
    Self::Item: ops::Add<Output = Self::Item> + Default,
    Self: Sized,
{
    self.fold(Self::Item::default(), |acc, x| acc + x)
}
```

すべての要素を足し合わせる`sum`メソッドです。`fold`を使ってシンプルに実装できます。
足しあわせるために`+`演算子が使えないといけません。そのためには、`Item`が`ops::Add`トレイトを実装している必要があります。また、初期値が必要なので、`Default`トレイトのデフォルト値を使います。これは、整数なら`0`、文字列なら空文字列、ベクタなら空ベクタを返すトレイトです。

初期値はデフォルト値で、畳み込み関数では`+`演算子を使って足し合わせます。

### `count`と`last`の簡略化

実は、`count`と`last`はもっと簡単に書けます。`fold`を使って一行で書けるんです。
リファクタリングしてみましょう。

引数の`mut`は不要になります。`fold`がイテレータを消費するので、`self`の所有権をムーブするだけで十分だからです。

```rust:src/iter.rs
fn count(self) -> usize
where
    Self: Sized,
{
    self.fold(0, |acc, _| acc + 1)
}

fn last(self) -> Option<Self::Item>
where
    Self: Sized,
{
    self.fold(None, |_, x| Some(x))
}
```

### 動作確認

`main.rs`で動作確認をしてみましょう。

```rust:src/main.rs
fn main() {
    let n = RangeUsize::new(0, 5).count();
    println!("[count] 0..5 => {}", n); // 5

    print!("[for_each] 0..5 =>");
    RangeUsize::new(0, 5).for_each(|x| print!(" {}", x));
    println!();

    let last = RangeUsize::new(10, 15).last();
    println!("[last] 10..15 => {:?}", last); // Some(14)

    let sum = RangeUsize::new(1, 6).fold(0usize, |acc, x| acc + x);
    println!("[fold] sum 1..6 => {}", sum); // 1+2+3+4+5 = 15

    let sum = RangeUsize::new(1, 6).sum();
    println!("[sum] sum 1..6 => {}", sum);

    let v = RangeUsize::new(3, 8).collect_vec();
    println!("[collect_vec] 3..8 => {:?}", v); // [3, 4, 5, 6, 7]

    let mut it = RangeUsize::new(100, 110);
    let third = it.nth(3); // 100,101,102,[103]...
    println!("[nth] 100..110 nth(3) => {:?}", third); // Some(103)
    let next = it.next();
    println!("[nth] then next() => {:?}", next); // Some(104)

    let mut it = RangeUsize::new(0, 20);
    let found = it.find(|x| *x % 7 == 0 && *x != 0);
    println!("[find] first nonzero multiple of 7 in 0..20 => {:?}", found); // Some(7)
    let after = it.next();
    println!("[find] then next() => {:?}", after); // Some(8)
}
```

```txt
[count] 0..5 => 5
[for_each] 0..5 => 0 1 2 3 4
[last] 10..15 => Some(14)
[fold] sum 1..6 => 15
[sum] sum 1..6 => 15
[collect_vec] 3..8 => [3, 4, 5, 6, 7]
[nth] 100..110 nth(3) => Some(103)
[nth] then next() => Some(104)
[find] first nonzero multiple of 7 in 0..20 => Some(7)
[find] then next() => Some(8)
```

ちゃんと呼び出せて、計算できています！
メソッドチェーンとまではいきませんが、イテレータを消費するメソッドが実装できました。

## 3. 変換系アダプタ - `Filter`

ここから、イテレータを変換する**変換系アダプタ**を実装していきます。
冒頭でも紹介したように、イテレータは遅延評価の特性を持っています。変換系アダプタは、イテレータの要素を変換したり、フィルタリングしたりするためのメソッドですが、実際に計算するのは、要素が必要になったとき（`next`が呼ばれたとき）です。

では、どうやって実行計画を表現しましょうか？
ここでは（そして標準ライブラリでも）、変換系アダプタごとに新しいイテレータ構造体を作成し、その中に元のイテレータと変換に必要な情報を保持する方法を採用します。
つまり`filter`用の新しい構造体を作って`MyIterator`トレイトを実装するということです。

### `Filter`構造体

イテレータをフィルターするには、元のイテレータと、フィルタリング条件を表すクロージャが必要です。これらを保持する`Filter`構造体を定義します。

```rust:src/adapter.rs
pub struct Filter<I, P> {
    inner: I,
    predicate: P,
}

impl<I, P> Filter<I, P> {
    pub fn new(iter: I, predicate: P) -> Self {
        Self {
            inner: iter,
            predicate,
        }
    }
}
```

`I`は元のイテレータの型、`P`はフィルタリング条件を表すクロージャの型です。

続いて、`MyIterator`トレイトを実装します。
`where`句にて`P`の型を`FnMut(&I::Item) -> bool`と制約することで、`I`の要素を参照で受け取り、真偽値を返すクロージャであることを示します。

フィルターしても型は変わらないので、`type Item = I::Item;`とします。

`next`メソッドは、元のイテレータの`next`を呼び出して、フィルタリング条件を満たす要素を返します。

```rust:src/adapter.rs
impl<I, P> MyIterator for Filter<I, P>
where
    I: MyIterator,
    P: FnMut(&I::Item) -> bool,
{
    type Item = I::Item;

    fn next(&mut self) -> Option<Self::Item> {
        while let Some(x) = self.inner.next() {
            if (self.predicate)(&x) {
                return Some(x);
            }
        }

        None
    }
}
```

### `MyIterator::filter`メソッド

`Filter`構造体を作成するメソッドを`MyIterator`トレイトに追加します。これにより、任意のイテレータから`filter`メソッドを呼び出せるようになります。

中では、`Filter`構造体を作成するだけです。

```rust:src/iter.rs
fn filter<P>(self, predicate: P) -> Filter<Self, P>
where
    P: FnMut(&Self::Item) -> bool,
    Self: Sized,
{
    Filter::new(self, predicate)
}
```

### 動作確認

実験してみましょう！
```rust:src/main.rs
fn main() {
    print!("[filter] even in 0..10 =>");
    RangeUsize::new(0, 10)
        .filter(|x| *x % 2 == 0)
        .for_each(|x| print!(" {}", x));
    println!(); // 0 2 4 6 8

    let n = RangeUsize::new(0, 100).filter(|x| *x % 3 == 0).count();
    println!("[filter+count] multiples of 3 in 0..100 => {}", n); // 34

    let last_even = RangeUsize::new(0, 10).filter(|x| *x % 2 == 0).last();
    println!("[filter+last] last even in 0..10 => {:?}", last_even); // Some(8)

    let sum_even = RangeUsize::new(1, 11).filter(|x| *x % 2 == 0).sum();
    println!("[filter+fold] sum of evens in 1..11 => {}", sum_even); // 2+4+6+8+10 = 30

    let v = RangeUsize::new(0, 20).filter(|x| *x % 7 == 0).collect_vec();
    println!("[filter+collect_vec] multiples of 7 in 0..20 => {:?}", v); // [0, 7, 14]

    let mut it = RangeUsize::new(0, 20).filter(|x| *x % 5 == 0);
    //  nth は「filter後の列」に対して数える
    let third = it.nth(3); // 0,5,10,[15]...
    println!("[filter+nth] (0..20).filter(%5==0).nth(3) => {:?}", third); // Some(15)
    let next = it.next(); // もう次は無い (0,5,10,15 で終わり)
    println!("[filter+nth] then next() => {:?}", next); // None
}
```

```txt
[filter] even in 0..10 => 0 2 4 6 8
[filter+count] multiples of 3 in 0..100 => 34
[filter+last] last even in 0..10 => Some(8)
[filter+fold] sum of evens in 1..11 => 30
[filter+collect_vec] multiples of 7 in 0..20 => [0, 7, 14]
[filter+nth] (0..20).filter(%5==0).nth(3) => Some(15)
[filter+nth] then next() => None
```

今作成した`filter`と、先ほどの消費系アダプタを組み合わせて使うことができました！

1. `RangeUsize`は`MyIterator`を実装しているため、`filter`を呼び出せる
2. `filter`は`Filter`構造体を返すが、これも`MyIterator`を実装している
3. そのため、`for_each`や`count`などの消費系アダプタを呼び出せる

という感じです。
何度も言いますが、重要なのは`filter`メソッドは計算を実行しないことです。消費系アダプタが`next`を呼び出したときに初めて、`Filter`構造体の`next`メソッドが実行され、元のイテレータから要素を取得し、フィルタリングが行われます。

この調子で`map`も実装していきましょう！

## 4. 変換系アダプタ - `Map`

要素を変換する`map`メソッドを作りましょう。これで、例えば数値を10倍にしたり、文字列を大文字に変換したりできるようになります。

### `Map`構造体

構造体の定義です。

```rust:src/adapter.rs
pub struct Map<I, F> {
    inner: I,
    f: F,
}

impl<I, F> Map<I, F> {
    pub fn new(iter: I, f: F) -> Self {
        Self { inner: iter, f }
    }
}
```

内側のイテレータと、変換関数を保持します。

また、こちらが`MyIterator`トレイトの実装です。
今度は型パラメータが3つありますね。`I`は元のイテレータ、`F`は変換関数、`B`は変換後の要素の型です。
制約は、`filter`と同様に、`I`がイテレータであることと、`F`が`I`の`Item`を受け取って`B`を返すクロージャであることを示しています。
`B`の型には特に制約はありません。どんな型を返しても困らないからです。

```rust:src/adapter.rs
impl<I, F, B> MyIterator for Map<I, F>
where
    I: MyIterator,
    F: FnMut(I::Item) -> B,
{
    type Item = B;

    fn next(&mut self) -> Option<Self::Item> {
        // これと同じ
        // Option::map(self.inner.next(), &mut self.f);
        self.inner.next().map(&mut self.f)
    }
}
```

あれ、`Map`の実装をしているのに、その中で`map`が使われています。

これは`Option`型の`map`メソッドです。このメソッドは値が`Some`であればクロージャを適用し、`None`であればそのまま`None`を返します。イテレータの`next`メソッドは`Option`型を返すので、これを使うとシンプルに書けます。`Option`であることを強調したいなら、コメントアウトしたコードのように書いても良いでしょう。Rustのメソッド呼び出しは糖衣構文（内部的には同じ処理に展開される、読みやすさのための構文）なので、どちらでも同じ意味になります。

### `MyIterator::map`メソッド

`MyIterator`への定義も忘れずに。

```rust:src/iter.rs
fn map<B, F>(self, f: F) -> Map<Self, F>
where
    F: FnMut(Self::Item) -> B,
    Self: Sized,
{
    Map::new(self, f)
}
```

### 動作確認

`filter`と組み合わせて動作させてみます。

```rust:src/main.rs
fn main() {
    print!("[filter+map] even in 0..10, then *10 =>");
    RangeUsize::new(0, 10)
        .filter(|x| *x % 2 == 0)
        .map(|x| x * 10)
        .for_each(|x| print!(" {}", x));
    println!(); // 0 20 40 60 80

    let v = RangeUsize::new(1, 21)
        .filter(|x| *x % 3 == 0)
        .map(|x| x * 100)
        .collect_vec();
    println!("[filter+map+collect_vec] multiples of 3 in 1..21 => {:?}", v);
    // [300, 600, 900, 1200, 1500, 1800]

    let sum = RangeUsize::new(1, 11)
        .filter(|x| *x % 2 == 1) // odd
        .map(|x| x * x)          // square
        .sum();
    println!("[filter+map+sum] sum of odd squares in 1..11 => {}", sum); // 1+9+25+49+81=165

    let mut it = RangeUsize::new(1, 100)
        .filter(|x| *x % 7 == 0)
        .map(|x| x + 1); // 7->8, 14->15, ...
    let found = it.find(|x| *x % 5 == 0); // 15 が最初に当たる
    println!("[filter+map+find] first (multiple of 7)+1 divisible by 5 => {:?}", found); // Some(15)
    let after = it.next();
    println!("[filter+map+find] then next() => {:?}", after); // Some(22)
}
```

```txt
[filter+map] even in 0..10, then *10 => 0 20 40 60 80
[filter+map+collect_vec] multiples of 3 in 1..21 => [300, 600, 900, 1200, 1500, 1800]
[filter+map+sum] sum of odd squares in 1..11 => 165
[filter+map+find] first (multiple of 7)+1 divisible by 5 => Some(15)
[filter+map+find] then next() => Some(22)
```

これで、`filter`と`map`を組み合わせてデータを処理できるようになりました。いくらでも長くチェーンできますね！
一番最初の処理の流れを追っておきます。

1. `RangeUsize`が`MyIterator`を実装しているので、`filter`メソッドを呼び出せる
1. `filter`は`Filter`構造体を返すが、これも`MyIterator`を実装している
1. そのため、`map`メソッドを呼び出せる
1. `map`は`Map`構造体を返すが、これも`MyIterator`を実装している
1. そのため、`for_each`メソッドを呼び出せる

しかし、`filter`も`map`も、せっかく構造体を作っているのに、内部状態がないですね。ただ関数を適用しているだけです。
というわけで、状態を持つ変換系アダプタも作ってみましょう！

## 5. 変換系アダプタ（内部状態あり）

最初からn個の要素をスキップする`skip`メソッドを作成します。何個スキップしているのかを覚えておく必要があります。これは状態を持つ変換系アダプタのいい例ですね。

### リファクタリング: モジュール分割

またまたコードが増えてきたので、`adapter.rs`をモジュール分割して整理しましょう。このままこのファイルにアダプターが追加され続けると、非常に読みにくくなってしまいます。
では、アダプターごとにファイルを分割していきましょう。
`filter.rs`、`map.rs`、`skip.rs`そして後で作る`Take`のための`take.rs`の4つのファイルに分割します。`filter.rs`と`map.rs`を適切に移動し、インポートを修正します。


:::details 実装

```rust:src/adapter.rs
pub mod filter;
pub mod map;
pub mod skip;
pub mod take;
```

```rust:src/adapter/filter.rsuse crate::iter::MyIterator;

pub struct Filter<I, P> {
    inner: I,
    predicate: P,
}

impl<I, P> Filter<I, P> {
    pub fn new(iter: I, predicate: P) -> Self {
        Self {
            inner: iter,
            predicate,
        }
    }
}
impl<I, P> MyIterator for Filter<I, P>
where
    I: MyIterator,
    P: FnMut(&I::Item) -> bool,
{
    type Item = I::Item;

    fn next(&mut self) -> Option<Self::Item> {
        while let Some(x) = self.inner.next() {
            if (self.predicate)(&x) {
                return Some(x);
            }
        }

        None
    }
}
```

```rust:src/adapter/map.rs

pub struct Map<I, F> {
    pub(crate) inner: I,
    pub(crate) f: F,
}

impl<I, F> Map<I, F> {
    pub fn new(iter: I, f: F) -> Self {
        Self { inner: iter, f }
    }
}

impl<I, F, B> MyIterator for Map<I, F>
where
    I: MyIterator,
    F: FnMut(I::Item) -> B,
{
    type Item = B;

    fn next(&mut self) -> Option<Self::Item> {
        // これと同じ
        // Option::map(self.inner.next(), &mut self.f);
        self.inner.next().map(&mut self.f)
    }
}
```

```rust:src/skip.rs
```

```rust:src/take.rs
```

:::

### `Skip`構造体

`Skip`構造体を定義します。あと何個の要素をスキップするのかを保持しています。

```rust:src/adapter/skip.rs
pub struct Skip<I> {
    inner: I,
    remaining: usize,
}

impl<I> Skip<I> {
    pub fn new(iter: I, n: usize) -> Self {
        Self {
            inner: iter,
            remaining: n,
        }
    }
}
```

そしていつも通り、`MyIterator`トレイトを実装します。

```rust:src/adapter/skip.rs
impl<I> MyIterator for Skip<I>
where
    I: MyIterator,
{
    type Item = I::Item;

    fn next(&mut self) -> Option<Self::Item> {
        let n = mem::take(&mut self.remaining);
        if n == 0 {
            self.inner.next()
        } else {
            self.inner.nth(n)
        }
    }
}
```

またまた新しい要素を入れてしまいました。`mem::take`は、変数の中身を取り出して、その変数を型のデフォルト値で置き換える関数です。ここでは`remaining`を取り出して`0`にリセットし、取り出した値を`n`に代入しています。

取り出した際に、残り回数がまだあるなら、`nth`メソッドを使って一気にスキップします。残り回数が0なら、そのまま`next`を呼び出して要素を返します。


### `MyIterator::skip`メソッド

いつも通り。

```rust:src/iter.rs
fn skip(self, n: usize) -> Skip<Self>
where
    Self: Sized,
{
    Skip::new(self, n)
}
```

### `Take`構造体

こちらは、最初のn個の要素だけのイテレータを作成する`Take`構造体です。
無限の要素を返すイテレータで、使用する要素数を決めたいときに便利です。

```rust:src/adapter/take.rs
pub struct Take<I> {
    inner: I,
    remaining: usize,
}

impl<I> Take<I> {
    pub fn new(iter: I, n: usize) -> Self {
        Self {
            inner: iter,
            remaining: n,
        }
    }
}
```

そして、`MyIterator`トレイトの実装です。
こちらは特に難しいことはなく、`remaining`が0になるまで要素を返し、0になったら`None`を返すだけです。

```rust:src/adapter/take.rs
impl<I> MyIterator for Take<I>
where
    I: MyIterator,
{
    type Item = I::Item;

    fn next(&mut self) -> Option<Self::Item> {
        if self.remaining == 0 {
            None
        } else {
            self.remaining -= 1;
            self.inner.next()
        }
    }
}
```

### `MyIterator::take`メソッド

```rust:src/iter.rs
fn take(self, n: usize) -> Take<Self>
where
    Self: Sized,
{
    Take::new(self, n)
}
```

### 動作確認

`skip`と`take`を組み合わせて動作確認をしてみましょう。

```rust:src/main.rs
fn main() {
    let v = RangeUsize::new(0, 10).skip(3).collect_vec();
    println!("[skip] 0..10 skip(3) => {:?}", v); // [3,4,5,6,7,8,9]

    let v = RangeUsize::new(0, 10).take(4).collect_vec();
    println!("[take] 0..10 take(4) => {:?}", v); // [0,1,2,3]

    // skipしてからtake
    let v = RangeUsize::new(0, 10).skip(3).take(4).collect_vec();
    println!("[skip+take] 0..10 skip(3).take(4) => {:?}", v); // [3,4,5,6]

    // takeしてからskip
    let v = RangeUsize::new(0, 10)
        .take(7) // [0,1,2,3,4,5,6]
        .skip(3) // [3,4,5,6]
        .collect_vec();
    println!("[take+skip] 0..10 take(7).skip(3) => {:?}", v); // [3,4,5,6]

    // skipが大きすぎると空
    let v = RangeUsize::new(0, 5).skip(100).collect_vec();
    println!("[skip too much] 0..5 skip(100) => {:?}", v); // []

    let v = RangeUsize::new(0, 5).take(0).collect_vec();
    println!("[take 0] 0..5 take(0) => {:?}", v); // []

    let s = RangeUsize::new(0, 10).skip(3).take(4).sum();
    println!("[sum] 0..10 skip(3).take(4) sum => {}", s); // 3+4+5+6 = 18

    let n = RangeUsize::new(0, 10).skip(3).take(4).count();
    println!("[count] 0..10 skip(3).take(4) count => {}", n); // 4

    let last = RangeUsize::new(0, 10).skip(3).take(4).last();
    println!("[last] 0..10 skip(3).take(4) last => {:?}", last); // Some(6)
}
```

```txt
[skip] 0..10 skip(3) => [3, 4, 5, 6, 7, 8, 9]
[take] 0..10 take(4) => [0, 1, 2, 3]
[skip+take] 0..10 skip(3).take(4) => [3, 4, 5, 6]
[take+skip] 0..10 take(7).skip(3) => [3, 4, 5, 6]
[skip too much] 0..5 skip(100) => []
[take 0] 0..5 take(0) => []
[sum] 0..10 skip(3).take(4) sum => 18
[count] 0..10 skip(3).take(4) count => 4
[last] 0..10 skip(3).take(4) last => Some(6)
```

ちゃんと動いていますね。

## 完成！

消費系アダプタと変換系アダプタの両方を実装できました。`RangeUsize`や``Counter`などのイテレータと組み合わせて、色々なデータ処理ができるようになりましたね！

本記事の冒頭で、`StdIter`を使って`Counter`を動かしましたよね。
今では、そのコードを自作イテレータで動作されられます。

```rust
let vec: Vec<usize> = Counter::new()
    .map(|x| x * 10)
    .filter(|x| x % 4 == 0)
    .skip(1)
    .take(10)
    .collect_vec();

println!("{vec:?}");
```

```txt
[20, 40, 60, 80, 100, 120, 140, 160, 180, 200]
```

この記事で作成した各種アダプタが連携し合い、複雑なデータ処理をメソッドチェーンでシンプルに表現できています。これにて完成ですね。

## 計画を覗き見る

遅延評価とは言ったものの、本当に遅延されているのでしょうか？気になりますね。実行の計画はただの構造体の組み合わせなので、これらを可視化すればいいのです。

Rustにある`Debug`トレイトを実装して、各アダプタの状態を表示できるようにしましょう。`derive`属性を使うと簡単に実装できます。

```rust:src/adapter/take.rs
#[derive(Debug)]
pub struct Take<I> {
    inner: I,
    remaining: usize,
}
```

```rust:src/adapter/skip.rs
#[derive(Debug)]
pub struct Skip<I> {
    inner: I,
    remaining: usize,
}
```

このようにして、構造体の定義の上に`#[derive(Debug)]`を追加します。しかし、`Filter`と`Map`はクロージャを保持しているため、`Debug`トレイトを自動導出できません。
`Debug`トレイトの自動導出は、すべてのフィールドが`Debug`トレイトを実装している場合にのみ可能だからです。クロージャは実装していません。

でも、構造体に制約を追加したくありませんねー。`Debug`がなくても動作には影響しないためです。
そこで、手動で`Debug`トレイトを実装します。
クロージャの部分は表示できないので、テキトーな文字列`|x| ...`で代用して表示するようにしましょう。
`where I: Debug`とありますが、これは内部のイテレータが`Debug`トレイトを実装している場合にのみ、この実装が有効になるという意味です。

```rust:src/adapter/filter.rs
impl<I, P> Debug for Filter<I, P> where I: Debug {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Filter")
            .field("inner", &self.inner)
            .field("predicate", &"|x| ...")
            .finish()
    }
}
```

```rust:src/adapter/map.rs
impl<I, F> Debug for Map<I, F> where I: Debug {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Map")
        .field("inner", &self.inner)
        .field("f", &"|x| ...")
        .finish()
    }
}
```

メソッドチェーンで割とわかりやすく定義できますね。

さて、イテレータの中身を覗いてみましょう！
`println!`マクロで、`{:?}`フォーマット指定子を使うと、`Debug`トレイトが実装されている型のデバッグ表現を表示できます。


```rust:src/main.rs
fn main() {
    let iter = Counter::new();
    println!("{iter:?}");

    let iter = iter.skip(5);
    println!("{iter:?}");

    let iter = iter.map(|x| x * 2);
    println!("{iter:?}");

    let iter = iter.filter(|x| x % 4 == 0);
    println!("{iter:#?}");

    let iter = iter.take(3);
    println!("{iter:#?}");
}
```

```txt
Counter { count: 0 }
Skip { inner: Counter { count: 0 }, remaining: 5 }
Map { inner: Skip { inner: Counter { count: 0 }, remaining: 5 }, f: "|x| ..." }
Filter {
    inner: Map {
        inner: Skip {
            inner: Counter {
                count: 0,
            },
            remaining: 5,
        },
        f: "|x| ...",
    },
    predicate: "|x| ...",
}
Take {
    inner: Filter {
        inner: Map {
            inner: Skip {
                inner: Counter {
                    count: 0,
                },
                remaining: 5,
            },
            f: "|x| ...",
        },
        predicate: "|x| ...",
    },
    remaining: 3,
}
```

最後の2つは大きいため、`{:#?}`フォーマット指定子を使って見やすくしています。
一番最後の`Take`を見てみましょうか。
`Take`の中に`Filter`があり、その中に`Map`があり、その中に`Skip`があり、その中に`Counter`がありますね。関数呼び出しで内側から処理されていくので、まさにメソッドチェーンで定義した順番通りです。

## おわりに

このような綺麗な設計を自分で思いつけるようになりたいですね😝💕

本記事は「KDIX CS Advent Calendar 2025」に参加しています。

https://qiita.com/advent-calendar/2025/kdixcs

