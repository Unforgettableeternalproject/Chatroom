"""啟動 Chatroom Hub：python -m chatroom_server"""

import uvicorn

from .app import create_app
from .config import Config
from .envfile import load_env_file


def main() -> None:
    # 先補 .env 再建 Config；真實環境變數優先，.env 只補缺
    load_env_file()
    cfg = Config()
    uvicorn.run(create_app(cfg), host=cfg.host, port=cfg.port)


if __name__ == "__main__":
    main()
