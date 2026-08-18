import random
import socket
from flask import Flask

app = Flask(__name__)

JOKES = [
    "Why don't scientists trust atoms? Because they make up everything!",
    "Why did the scarecrow win an award? Because he was outstanding in his field!",
    "Why don't skeletons fight each other? They don't have the guts.",
    "What do you call fake spaghetti? An impasta!",
    "Why did the bicycle fall over? Because it was two-tired!"
]

@app.route("/")
def tell_a_joke():
    joke = random.choice(JOKES)
    hostname = socket.gethostname()
    return f"{joke}\n(Served by: {hostname})"

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
