import random
import socket
from fastapi import FastAPI

app = FastAPI()

JOKES = [
    "Why don't scientists trust atoms? Because they make up everything!",
    "Why did the scarecrow win an award? Because he was outstanding in his field!",
    "Why don't skeletons fight each other? They don't have the guts.",
    "What do you call fake spaghetti? An impasta!",
    "Why did the bicycle fall over? Because it was two-tired!"
]

@app.get("/")
async def tell_a_joke():
    joke = random.choice(JOKES)
    hostname = socket.gethostname()
    return {"joke": joke, "served_by": hostname}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
