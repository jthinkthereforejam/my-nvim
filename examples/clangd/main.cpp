#include <cstdio>

struct GameState {
    int frame = 0;
};

int main() {
    GameState state;
    ++state.frame;
    std::printf("frame %d\n", state.frame);
    return 0;
}
