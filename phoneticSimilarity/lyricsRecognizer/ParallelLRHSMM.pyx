import numpy as np
from scipy.stats import norm
import time
import matplotlib.pyplot as plt

cimport numpy as np
cimport cython

from LRHMM import _LRHMM
from general.phonemeMap import *
from general.parameters import *

import os,sys
# import json

def transcriptionMapping(transcription):
    transcription_maped = []
    for t in transcription:
        transcription_maped.append(dic_pho_map[t])
    return transcription_maped


class ParallelLRHSMM(_LRHMM):

    def __init__(self,lyrics,mat_trans_comb,state_pho_comb,index_start,index_end,mean_dur_state,proportionality_std):
        _LRHMM.__init__(self)

        self.lyrics         = lyrics
        self.A              = mat_trans_comb
        self.transcription  = state_pho_comb
        self.idx_final_head = index_start           # index of head (start) state for each path in the network
        self.idx_final_tail = index_end             # index of tail (ending) state for each path in the network
        self.mean_dur_state = mean_dur_state        # duration of each state
        self.proportionality_std = proportionality_std
        self.n              = len(self.transcription)
        self._initialStateDist()

    def _initialStateDist(self):
        '''
        explicitly set the initial state distribution
        '''
        # list_forced_beginning = [u'nvc', u'vc', u'w']
        self.pi     = np.zeros((self.n), dtype=self.precision)

        # each final head has a change to start
        for ii in self.idx_final_head:
            self.pi[ii] = 1.0
        self.pi /= sum(self.pi)

    # def _makeNet(self):
    #     pass

    def _inferenceInit(self,observations):
        '''
        HSMM inference initialization
        :param observations:
        :return:
        '''

        tau = len(observations)

        # Forward quantities
        forwardDelta        = np.ones((self.n,tau),dtype=self.precision)
        forwardDelta        *= -float('inf')
        previousState       = np.zeros((self.n,tau),dtype=np.intc)
        state               = np.zeros((self.n,tau),dtype=np.intc)
        occupancy           = np.zeros((self.n,tau),dtype=np.intc)

        # State-in
        # REMARK : state-in a time t is StateIn(:,t+1), such that StateIn(:1) is
        # the initial distribution
        stateIn             = np.ones((self.n,tau),dtype=self.precision)
        stateIn             *= -float('inf')

        # Set initial states distribution \pi %%%%            % PARAMETERs
        # stateIn[:,0]        = np.log(self.pi)

        # # simplify A
        # A   = np.zeros((self.n,self.n),dtype=self.precision)
        # for jj in xrange(self.n):
        #     for ii in xrange(self.n):
        #         if isinstance(self.A[ii][jj],np.ndarray):
        #             A[ii][jj] = self.A[ii][jj][0]
        #         else:
        #             A[ii][jj] = self.A[ii][jj]

        return forwardDelta,\
               previousState,\
                state,\
               stateIn,\
                occupancy

    @cython.cdivision(True)
    @cython.boundscheck(False)
    @cython.wraparound(False)
    def _viterbiHSMM(self,observations,am='gmm'):

        forwardDelta,\
           previousState,\
            state,\
           stateIn,\
            occupancy      = self._inferenceInit(observations)

        tau = len(observations)

        cdef double [:, ::1] cA             = np.log(self.A)
        cdef double [:, ::1] cforwardDelta  = forwardDelta
        cdef int [:, ::1] cpreviousState    = previousState
        cdef int [:, ::1] cstate            = state
        cdef double [:, ::1] cstateIn       = stateIn
        cdef int [:, ::1] coccupancy        = occupancy

        # calculate the observation probability and normalize for each frame into pdf sum(B_map[:,t])=1
        if am=='gmm':
            self._mapBGMM(observations)
        elif am == 'dnn':
            self._mapBDNN(observations)
        # obs = np.exp(self.B_map)
        # obs /= np.sum(obs,axis=0)

        # cdef double [:, ::1] cobs   = np.log(obs)
        cdef double [::1] cpi       = np.log(self.pi)
        cdef double cmaxForward     = -float('inf') # max value in time T (max)

        # print pi
        # print self.net.getStates()
        # print self.transcription


        # get transition probability and others
        # A,idx_loop_enter,idx_loop_skip_self,tracker_loop_enter = self.viterbiTransitionVaryingHelper()

        # print self.A

        # predefine M,d,D
        M = []
        max_mean_dur    = max(self.mean_dur_state)
        max_std_dur     = self.proportionality_std*max_mean_dur
        # x is generated as the index of the largest phoneme duration
        x               = np.arange(0,max_mean_dur+10*max_std_dur,hopsize_t_phoneticSimilarity)
        d = np.zeros((self.n,len(x)),dtype=self.precision)
        D = np.zeros((self.n,len(x)),dtype=self.precision)

        for j in xrange(self.n):
            mean_j          = self.mean_dur_state[j]
            std_j           = self.proportionality_std*mean_j
            M.append(int((mean_j+10*std_j)/hopsize_t_phoneticSimilarity)-1)
            d[j,:]          = norm.logpdf(x,mean_j,std_j)
            D[j,:]          = norm.logsf(x,mean_j,std_j)

        cdef int [::1] cM   = np.array(M,dtype=np.intc)
        cdef double[:,::1] cd = d
        cdef double[:,::1] cD = D

        # version in guedon 2003 paper
        for t in xrange(0,tau):
            print t
            for j in xrange(self.n):

                xsampa_state = self.transcription[j]

                # print M_j
                # print tau

                observ          = 0.0

                if t<tau-1:
                    for u in xrange(1,min(t+1,cM[j])+1):
                        observ += self.B_map[xsampa_state][t-u+1]
                        if u < t+1:
                            prod_occupancy = observ+cd[j][u]+cstateIn[j,t-u+1]
                            # print t, j, prod_occupancy, observ, cd[j][u], cstateIn[j,t-u+1]
                            if prod_occupancy > cforwardDelta[j,t]:
                                cforwardDelta[j,t]   = prod_occupancy
                                cpreviousState[j,t]  = cstate[j,t-u+1]
                                coccupancy[j,t]      = u
                        else:
                            # print u, len(occupancies_j)
                            prod_occupancy  = observ+cd[j][t+1]+cpi[j]
                            # print t, j, prod_occupancy, observ, d[j][u], cpi[j]
                            if prod_occupancy > cforwardDelta[j,t]:
                                cforwardDelta[j,t]   = prod_occupancy
                                coccupancy[j,t]      = t+1

                else:
                    for u in xrange(1,min(tau,cM[j])+1):
                        # observ *= obs[j,tau-u]
                        # observ += cobs[j,tau-u]
                        observ += self.B_map[xsampa_state][tau-u]
                        if u < tau:
                            prod_survivor = observ+cD[j][u]+cstateIn[j,tau-u]
                            # print t, j, prod_survivor, observ, cD[j][u], cstateIn[j,tau-u]
                            if prod_survivor > cforwardDelta[j,tau-1]:
                                cforwardDelta[j,tau-1]   = prod_survivor
                                cpreviousState[j,t]      = cstate[j,tau-u]
                                coccupancy[j,tau-1]      = u

                        else:
                            prod_survivor = observ+cD[j][tau]+cpi[j]
                            # print t, j, prod_survivor, observ, cD[j][u], cpi[j]
                            if prod_survivor > cforwardDelta[j,tau-1]:
                                cforwardDelta[j,tau-1]   = prod_survivor
                                coccupancy[j,tau-1]      = tau

            # ignore normalization

            if t<tau-1:
                for j in xrange(self.n):
                    for i in xrange(self.n):

                        if cstateIn[j,t+1] < cA[i][j] + cforwardDelta[i,t]:
                            cstateIn[j,t+1]        = cA[i][j] + cforwardDelta[i,t]
                            cstate[j,t+1]          = i


        # termination: find the maximum probability for the entire sequence (=highest prob path)

        # for i in xrange(self.n):
        #     # decode only possible from the final node of each path
        #     ii = i-1 if self.n > len(self.phos_final) else i
        #     if ii in self.idx_final_tail: endingProb = np.log(1.0)
        #     else: endingProb = np.log(0.0)
        #
        #     # print stateIn[i][len(observations)-1]
        #     if (cmaxForward < cforwardDelta[i][tau-1]+endingProb):
        #         cmaxForward = cforwardDelta[i][tau-1]+endingProb
        #         cpath[tau-1] = i

        posteri_probs   = np.zeros((len(self.idx_final_tail),),dtype=self.precision)
        counter_posteri = 0
        paths           = []
        for i in xrange(self.n):
            if i in self.idx_final_tail:
                # print self.idx_final_tail
                # print i
                # endingProb = 0.0

                posteri_probs[counter_posteri] = cforwardDelta[i][tau-1]

                # tracking all parallel paths
                path            = np.zeros((tau),dtype=np.intc)
                path[tau-1]     = i
                t = tau-1

                while t>=0:
                    j = path[t]
                    u = coccupancy[j,t]
                    if j == 0 and u == 0:
                        # this is the case that poster_probs is -INFINITY
                        # dead loop
                        path[:] = j
                        break
                    for v in xrange(1,u):
                        path[t-v] = j
                    if t >= u:
                        path[t-u] = cpreviousState[j,t]
                    t = t-u

                paths.append(path)
                counter_posteri += 1
            else:
                pass
        '''
        t = tau-1

        while t>=0:
            j = cpath[t]
            u = coccupancy[j,t]
            # print t,j,u
            for v in xrange(1,u):
                cpath[t-v] = j
            if t >= u:
                cpath[t-u] = cpreviousState[j,t]
            t = t-u
        '''

        return paths,posteri_probs

    def _pathStateDur(self,path):
        '''
        path states in phoneme and duration
        :param path:
        :return:
        '''
        dur_frame = 1
        state_dur_path = []
        for ii in xrange(1,len(path)):
            if path[ii] != path[ii-1]:
                state_dur_path.append([self.transcription[int(path[ii-1])], dur_frame * hopsize_phoneticSimilarity / float(fs)])
                dur_frame = 1
            else:
                dur_frame += 1
        state_dur_path.append([self.transcription[int(path[-1])], dur_frame * hopsize_phoneticSimilarity / float(fs)])
        return state_dur_path

    def _plotNetwork(self,path):
        self.net.plotNetwork(path)

    def _pathPlot(self,transcription_gt,path_gt,path):
        '''
        plot ground truth path and decoded path
        :return:
        '''

        ##-- unique transcription and path
        transcription_unique = []
        transcription_number_unique = []
        B_map_unique = np.array([])
        for ii,t in enumerate(self.transcription):
            if t not in transcription_unique:
                transcription_unique.append(t)
                transcription_number_unique.append(ii)
                if not len(B_map_unique):
                    B_map_unique = self.B_map[t]
                else:
                    B_map_unique = np.vstack((B_map_unique,self.B_map[t]))

        trans2transUniqueMapping = {}
        for ii in range(len(self.transcription)):
            trans2transUniqueMapping[ii] = transcription_unique.index(self.transcription[ii])

        path_unique = []
        for ii in range(len(path)):
            path_unique.append(trans2transUniqueMapping[path[ii]])

        ##-- figure plot
        plt.figure()
        n_states = B_map_unique.shape[0]
        n_frame  = B_map_unique.shape[1]
        y = np.arange(n_states+1)
        x = np.arange(n_frame) * hopsize_phoneticSimilarity / float(fs)

        plt.pcolormesh(x,y,B_map_unique)
        plt.plot(x,path_unique,'b',linewidth=3)
        plt.xlabel('time (s)')
        plt.ylabel('states')
        plt.yticks(y, transcription_unique, rotation='horizontal')
        plt.show()

    def _getBestMatchLyrics(self,path):
        idx_best_match = self.idx_final_head.index(path[0])
        return self.lyrics[idx_best_match]

    def _getAllInfo(self):
        return