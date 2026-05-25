# install nvm per-user into ~/.nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash

# load it now, without reopening terminal
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# install current LTS Node.js; npm comes with it
nvm install --lts
nvm alias default 'lts/*'
nvm use default

# verify
node -v
npm -v
npx -v
which node
which npm
