
# Generic Vertex
glslangValidator -V generic.vert -o generic.vert.spv
glslangValidator -V generic.frag -o generic.frag.spv

# Texture Vertex
glslangValidator -V texture.vert -o texture.vert.spv
glslangValidator -V texture.frag -o texture.frag.spv

echo 'Done'
