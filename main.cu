#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <float.h>
#include <math.h>
#include <iostream>
#include "libarff/arff_parser.h"
#include "libarff/arff_data.h"

// -----------
#include <climits>         // for MAX_INT
#include <bits/stdc++.h>   // for sorting
// -----------

#define THREADS_DIM 16


using namespace std;

int* KNN(ArffData* dataset, int k, int* predictions)
{
    // predictions is the array where you have to return the class predicted (integer) for the dataset instances
    int* predictions = (int*)malloc(dataset->num_instances() * sizeof(int));
    
    // The following two lines show the syntax to retrieve the attribute values and the class value for a given instance in the dataset
    // float attributeValue = dataset->get_instance(instanceIndex)->get(attributeIndex)->operator float();
    // int classValue =  dataset->get_instance(instanceIndex)->get(dataset->num_attributes() - 1)->operator int32();
    
    // Implement the KNN here, fill the predictions array

    for(int i = 0; i < dataset->num_instances(); i++)
    {

        // getNeighbors()
        int neighbors[5];
        tuple<int, double>* distances = (tuple<int, double>*)malloc(dataset->num_instances() * sizeof(tuple<int, double>));
        for(int j = 0; j < dataset->num_instances(); j++)
        {

            // map(dataset, (train) => (train, distance(train)))
            if(j == i)
            {
                distances[j] = tuple<int, double>(j, INT_MAX);
                continue;
            }

            long squaredSum = 0;
            for(int y = 0; y < dataset->num_attributes() - 1; y++)
            {
                squaredSum += pow(dataset->get_instance(i)->get(y)->operator float() - dataset->get_instance(j)->get(y)->operator float(),  2);
            }

            distances[j] = tuple<int, double>(j, sqrt(squaredSum));
        }

        // distances.sort()
        sort(distances, distances + dataset->num_instances(), [](tuple<int, double> a, tuple<int, double> b) {
            return get<1>(a) < get<1>(b);
        });

        // distances.take(5)
        for(int x = 0; x < k; x++)
        {
            neighbors[x] = get<0>(distances[x]);
        }

        // map(neighbors, (x) => neighbors.class)
        int outputValues[k];
        for(int j = 0; j < k; j++)
        {
            outputValues[j] = dataset->get_instance(neighbors[j])->get(dataset->num_attributes() - 1)->operator int32();
        }

        // mode()
        map<int, int> histogram;

        int mode_count = 0;
        int mode = -1;
        for(int a = 0; a < k; a++) 
        {
            int element = outputValues[a];
            histogram[element]++;
            if(histogram[element] > mode_count)
            {
                mode_count = histogram[element];
                mode = element;
            }
        }

        predictions[i] = mode;
        free(distances);
    }
}

__global__ int* KNN_GPU(ArffData* dataset, int k, int* predictions)
{

    int row = blockIdx.x * blockDim.x + threadIdx.x; // Some combination of threadId and blockId

    if(row < dataset->num_instances())
    {
        // getNeighbors()
        int neighbors[5];
        tuple<int, double>* distances = (tuple<int, double>*)malloc(dataset->num_instances() * sizeof(tuple<int, double>));
        for(int j = 0; j < dataset->num_instances(); j++)
        {

            // map(dataset, (train) => (train, distance(train)))
            if(j == row)
            {
                distances[j] = tuple<int, double>(j, INT_MAX);
                continue;
            }

            long squaredSum = 0;
            for(int y = 0; y < dataset->num_attributes() - 1; y++)
            {
                squaredSum += pow(dataset->get_instance(row)->get(y)->operator float() - dataset->get_instance(j)->get(y)->operator float(),  2);
            }

            distances[j] = tuple<int, double>(j, sqrt(squaredSum));
        }

        // distances.sort()
        sort(distances, distances + dataset->num_instances(), [](tuple<int, double> a, tuple<int, double> b) {
            return get<1>(a) < get<1>(b);
        });

        // distances.take(5)
        for(int x = 0; x < k; x++)
        {
            neighbors[x] = get<0>(distances[x]);
        }

        // map(neighbors, (x) => neighbors.class)
        int outputValues[k];
        for(int j = 0; j < k; j++)
        {
            outputValues[j] = dataset->get_instance(neighbors[j])->get(dataset->num_attributes() - 1)->operator int32();
        }

        // mode()
        map<int, int> histogram;

        int mode_count = 0;
        int mode = -1;
        for(int a = 0; a < k; a++) 
        {
            int element = outputValues[a];
            histogram[element]++;
            if(histogram[element] > mode_count)
            {
                mode_count = histogram[element];
                mode = element;
            }
        }

        predictions[row] = mode;
        free(distances);
    }
}

int* computeConfusionMatrix(int* predictions, ArffData* dataset)
{
    int* confusionMatrix = (int*)calloc(dataset->num_classes() * dataset->num_classes(), sizeof(int)); // matrix size numberClasses x numberClasses
    
    for(int i = 0; i < dataset->num_instances(); i++) // for each instance compare the true class and predicted class
    {
        int trueClass = dataset->get_instance(i)->get(dataset->num_attributes() - 1)->operator int32();
        int predictedClass = predictions[i];
        
        confusionMatrix[trueClass*dataset->num_classes() + predictedClass]++;
    }
    
    return confusionMatrix;
}

float computeAccuracy(int* confusionMatrix, ArffData* dataset)
{
    int successfulPredictions = 0;
    
    for(int i = 0; i < dataset->num_classes(); i++)
    {
        successfulPredictions += confusionMatrix[i*dataset->num_classes() + i]; // elements in the diagonal are correct predictions
    }
    
    return successfulPredictions / (float) dataset->num_instances();
}

int main(int argc, char *argv[])
{
    if(argc != 3)
    {
        cout << "Usage: ./main datasets/datasetFile.arff k" << endl;
        exit(0);
    }

    // Get k
    int k = atoi(argv[2]);

    // Open the dataset
    ArffParser parser(argv[1]);
    ArffData *dataset = parser.parse();

    // Allocate Memory
    int* predictionsHostCPU;
    int* predictionsHost;
    int* predictionsDevice;

    cudaMalloc(&predictionsDevice, dataset->num_instances() * sizeof(int));
    cudaMallocHost(&predictionsHost, dataset->num_instances() * sizeof(int));
    cudaMallocHost(&predictionsHostCPU, dataset->num_instances() * sizeof(int));

    int gridDim = (dataset->num_instances() + THREADS_DIM - 1) / THREADS_DIM;

    dim3 blockSize (THREADS_DIM, THREADS_DIM);
    dim3 gridSize (gridDim, gridDim);

    // --------------------------- CPU ---------------
   
    struct timespec start, end;

    clock_gettime(CLOCK_MONOTONIC_RAW, &start);
    
    // Get the class predictions
    KNN(dataset, k, predictionsHostCPU);
    // Compute the confusion matrix
    int* confusionMatrix = computeConfusionMatrix(predictionsHostCPU, dataset);
    // Calculate the accuracy
    float accuracy = computeAccuracy(confusionMatrix, dataset);
    
    clock_gettime(CLOCK_MONOTONIC_RAW, &end);
    uint64_t diff = (1000000000L * (end.tv_sec - start.tv_sec) + end.tv_nsec - start.tv_nsec) / 1e6;

    printf("The KNN classifier for %lu instances required %llu ms CPU time, accuracy was %.4f\n", dataset->num_instances(), (long long unsigned int) diff, accuracy);

    // ----------------------------- GPU -------------------------


    clock_gettime(CLOCK_MONOTONIC_RAW, &start);
    
    // Get the class predictions
    KNN_GPU<<< gridSize, blockSize >>>(dataset, k, predictionsDevice);

    cudaMemcpy(predictionsHost, predictionsDevice, dataset->num_instances() * sizeof(int), cudaMemcpyDeviceToHost);

    // Compute the confusion matrix
    int* confusionMatrixGPU = computeConfusionMatrix(predictionsHost, dataset);
    // Calculate the accuracy
    float accuracyGPU = computeAccuracy(confusionMatrixGPU, dataset);

    clock_gettime(CLOCK_MONOTONIC_RAW, &end);
    uint64_t diffMP = (1000000000L * (end.tv_sec - start.tv_sec) + end.tv_nsec - start.tv_nsec) / 1e6;

    printf("The KNN classifier on the GPU for %lu instances required %llu ms CPU time, accuracy was %.4f\n", dataset->num_instances(), (long long unsigned int) diffGPU, accuracyGPU);

    // Free memory
    cudaFree(predictionsDevice);
    cudaFreeHost(predictionsHost);
}
