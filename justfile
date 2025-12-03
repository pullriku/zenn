list:
    just --list

# 新しい記事を作成する
preview:
    bunx --bun zenn preview

# 新しい本を作成する
new-article slug:
    bunx --bun zenn new:article --slug {{slug}}

# 投稿をプレビューする
new-book slug:
    bunx --bun zenn new:book --slug {{slug}}
