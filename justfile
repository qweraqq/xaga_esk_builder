set shell := ["bash", "-euo", "pipefail", "-c"]

alias b := build
alias f := fmt
alias g := generic
alias gd := git-diff
alias gl := git-log
alias gs := git-status
alias gsh := git-show
alias x := xaga

default:
    @just --list

fmt:
    git ls-files -z '*.sh' | xargs -0r shfmt -w -i 4 -ci -bn -sr "${scripts[@]}"

fmt-check:
    git ls-files -z '*.sh' | xargs -0r shfmt -d -i 4 -ci -bn -sr "${scripts[@]}"

lint:
    git ls-files -z '*.sh' | xargs -0r shellcheck "${scripts[@]}"

check: fmt-check lint

git-status:
    git status --short --branch

git-diff *args:
    git diff {{args}}

git-log limit="20":
    git log --oneline --decorate --graph -n {{limit}}

git-show ref="HEAD":
    git show --stat --patch {{ref}}

build *args:
    env {{args}} ./build.sh

xaga *args:
    env BUILD_TARGET=xaga {{args}} ./build.sh

generic *args:
    env BUILD_TARGET=generic {{args}} ./build.sh

clean:
    rm -rf out work staged boot_image build.log github.json
