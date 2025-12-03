list:
    just --list

# 投稿をプレビューする
preview:
    bunx --bun zenn preview

# 新しい本を作成する
new-article slug:
    bunx --bun zenn new:article --slug {{slug}}
    mkdir -p images/articles/{{slug}}

remove-article slug:
    rm -rf articles/{{slug}}.md
    rm -rf images/articles/{{slug}}

# 新しい記事を作成する
new-book slug:
    bunx --bun zenn new:book --slug {{slug}}
    mkdir -p images/books/{{slug}}
