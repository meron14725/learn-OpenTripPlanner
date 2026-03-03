from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from api.routes import router

app = FastAPI(title="執事アプリ API")
app.include_router(router)


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    """エラーレスポンスを { "error": { "code": "...", "message": "..." } } 形式に統一"""
    return JSONResponse(
        status_code=exc.status_code,
        content={
            "error": {
                "code": exc.headers.get("X-Error-Code", "UNKNOWN") if exc.headers else "UNKNOWN",
                "message": exc.detail,
            }
        },
    )
