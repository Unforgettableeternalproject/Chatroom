"""啟動 Chatroom Hub：python -m chatroom_server"""

import uvicorn

from .app import create_app
from .config import Config


def main() -> None:
    cfg = Config()
    uvicorn.run(create_app(cfg), host=cfg.host, port=cfg.port)


if __name__ == "__main__":
    main()
